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
has local_addr => sub { $_[0]->connection->local_addr };

my %req_types = (
    ACCEPT => \&req_accept,
    CHAT   => \&req_chat,
    RESUME => \&req_resume,
    SEND   => \&req_send,
);

sub _addr_to_ip {
  my $addr = shift;

  # if it's an ipv6 addr, no need to convert it
  my $ip = $addr =~ /:/ ? $addr : inet_ntoa pack "N", $addr;
  warn "addr => $addr => $ip\n" if DEBUG == 2;

  return $ip
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

  warn sprintf "[%s] %s\n", $self->connection->{debug_key}, "=== ACCEPT (" . join(", ", @params{qw/ nick file port pos /} ) . ")" if DEBUG == 2;
  $self->emit(accept => $params{nick}, $params{file}, $params{port}, $params{pos});
}

sub req_chat {
  my ($self, %params) = @_;
  $params{protocol} = delete $params{file}; # just a naming thing
  $params{ip} = _addr_to_ip delete $params{addr};

  warn sprintf "[%s] %s\n", $self->connection->{debug_key}, "=== CHAT (" . join(", ", @params{qw/ nick protocol ip port /} ) . ")" if DEBUG == 2;
  $self->emit(chat => $params{nick}, $params{protocol}, $params{ip}, $params{port});
}

sub req_resume {
  my ($self, %params) = @_;
  $params{pos} = delete $params{size}; # just a naming thing

  warn sprintf "[%s] %s\n", $self->connection->{debug_key}, "=== RESUME (" . join(", ", @params{qw/ nick file port pos /} ) . ")" if DEBUG == 2;
  $self->emit(resume => $params{nick}, $params{file}, $params{port}, $params{pos});
}

sub req_send {
  my ($self, %params) = @_;
  $params{ip} = _addr_to_ip delete $params{addr};

  warn sprintf "[%s] %s\n", $self->connection->{debug_key}, "=== SEND (" . join(", ", @params{qw/ nick file ip port /}, defined $params{size} ? $params{size} : ()) . ")" if DEBUG == 2;
  $self->emit(send => $params{nick}, $params{file}, $params{ip}, $params{port}, $params{size});
}

1;
