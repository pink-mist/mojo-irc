package Mojo::IRC::DCC;
use Mojo::Base 'Mojo::EventEmitter';
use Mojo::IOLoop;
use Mojo::Util qw/ dumper /;
use Fcntl qw/ O_CREAT O_WRONLY /;
use Parse::IRC ();
use Socket qw/ inet_ntoa /;
use constant DEBUG => $ENV{MOJO_IRC_DEBUG} || 0;

has 'connection';
has timeout => sub { 3*60 };
has local_address => sub { $_[0]->connection->local_address };

my %req_types = (
    ACCEPT => \&req_accept,
    CHAT   => \&req_chat,
    RESUME => \&req_resume,
    SEND   => \&req_send,
);

sub _accept {
  my ($self, %params) = @_;

  my ($nick, $file, $port, $pos) = @params{qw/ nick file port pos/};

  if (defined(my $p = delete $self->{resumes}{$nick}{$file}{$port})) {
    Mojo::IOLoop->remove(delete $p->{tid});
    $self->_get(%{ $p }, pos => $pos);
  }

  return $self;
}

sub _addr_to_ip {
  my $addr = shift;

  # if it's an ipv6 addr, no need to convert it
  my $ip = $addr =~ /:/ ? $addr : inet_ntoa pack "N", $addr;
  warn "addr => $addr => $ip\n" if DEBUG == 2;

  return $ip
}

sub get {
  my ($self, %params) = @_;

  $params{local} .= '/' . $params{file}
    if defined $params{local} and -d $params{local};

  return $self->_get(%params)
    if not defined $params{local} or ! -s $params{local};

  return $self->emit(error =>
    "File '$params{local}' already exists and resume => 1 wasn't given.")
    if not $params{resume};

  return $self->emit(error =>
    "File '$params{local}' already exists and is not smaller than the file being sent.")
    if not -s $params{local} < $params{size};

  return $self->_resume(%params);
}

sub _get {
  my ($self, %params) = @_;

  $params{pos} //= 0;
  my ($nick, $file, $ip, $port, $pos, $size, $local, $cb) =
    @params{qw/ nick file ip port pos size local cb /};

  my $fh;
  if (defined $local) {
    sysopen $fh, $local, O_CREAT|O_WRONLY or
      return $self->emit(error => "Could not open '$local': $!");
    seek $fh, $pos, 0 or
      return $self->emit(error => "Could not seek '$local': $!")
      if $pos;
  }

  my @extra;
  if (defined $self->local_address) {
    push @extra, local_address => $self->local_address;
  }

  my $recv = $pos;
  $self->{gets}{$nick}{$file}{$port} = Mojo::IOLoop->client(
    address => $ip,
    port    => $port,
    timeout => $self->timeout,
    @extra,
    sub {
      my ($l, $e, $s) = @_;

      if ($e) {
        delete $self->{gets}{$nick}{$file}{$port};
        return $self->emit(error => $e);
      }

      $s->timeout(0);

      $s->on(
        error => sub {
          Mojo::IOLoop->remove(delete $self->{gets}{$nick}{$file}{$port});
          $self->emit(error => $_[1]);
        }
      );
      $s->on(
        read => sub {
          $recv += length($_[1]);
          print $fh $_[1] if defined $fh;
          $cb->($_[1], $pos, $recv, $size) if defined $cb;
          $s->write(_long($recv)) if not $params{turbo};
        }
      );
      $s->on(
        close => sub {
          delete $self->{gets}{$nick}{$file}{$port};
          $self->emit(close => %params, recv => $recv);
        }
      );
    }
  );

  return $self;
}

sub _q {
  my $str = shift;
  $str = qq("$str") if $str =~ / /;

  return $str;
}

sub req {
  my ($self, $message) = @_;

  if (defined(my $cb = $req_types{$message->{params}[2]{type}})) {
    $self->$cb(%{$message->{params}[2]});
  } else {
    $self->emit(unknown => $message);
  }

  return $self;
}

sub req_accept {
  my ($self, %params) = @_;
  $params{pos} = delete $params{size}; # just a naming thing

  warn sprintf "[%s] %s\n",
    $self->connection->{debug_key},
    "=== ACCEPT => " . join(", ", map "$_ => '$params{$_}'", sort keys %params)
    if DEBUG == 2;
  $self->_accept(%params);
  $self->emit(accept => %params);
}

sub req_chat {
  my ($self, %params) = @_;
  $params{protocol} = delete $params{file}; # just a naming thing
  $params{ip} = _addr_to_ip delete $params{addr};

  warn sprintf "[%s] %s\n",
    $self->connection->{debug_key},
    "=== CHAT => " . join(", ", map "$_ => '$params{$_}'", sort keys %params)
    if DEBUG == 2;
  $self->emit(chat => %params);
}

sub req_resume {
  my ($self, %params) = @_;
  $params{pos} = delete $params{size}; # just a naming thing

  warn sprintf "[%s] %s\n",
    $self->connection->{debug_key},
    "=== RESUME => " . join(", ", map "$_ => '$params{$_}'", sort keys %params)
    if DEBUG == 2;
  $self->emit(resume => %params);
}

sub req_send {
  my ($self, %params) = @_;
  $params{ip} = _addr_to_ip delete $params{addr};

  warn sprintf "[%s] %s\n",
    $self->connection->{debug_key},
    "=== SEND => " . join(", ", map "$_ => '$params{$_}'", sort keys %params)
    if DEBUG == 2;
  $self->emit(send => %params);
}

sub _resume {
  my ($self, %params) = @_;

  my ($nick, $file, $port, $local) = @params{qw/ nick file port local /};
  my $pos = $params{pos} = -s $local;

  $self->{resumes}{$nick}{$file}{$port} = \%params;

  my $err_cb = sub {
    Mojo::IOLoop->remove(delete $params{tid});
    delete $self->{resumes}{$nick}{$file}{$port};
    $self->emit(error => $_[1]);
  };

  $params{tid} = Mojo::IOLoop->timer($self->timeout,
    sub { $self->$err_cb("Resume timed out for '$local'."); });

  $self->write(
    PRIVMSG => $nick,
    $self->ctcp(DCC => RESUME => _q($file), $port, $pos),
    $err_cb
  );
}

1;
