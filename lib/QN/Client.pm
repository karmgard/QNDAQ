package Client;

use strict;
use warnings;

use threads;
use threads::shared;

use Time::HiRes qw(usleep);

use IO::Socket;
use IO::Select;

use QN::ThreadQueue;

sub new {
    my ( $class, $host, $port ) = @_;
    my $proto = getprotobyname('tcp');

    my $socket = new IO::Socket::INET (
	PeerAddr  => $host,
	Proto     => $proto,
	PeerPort  => $port,
	ReuseAddr => 1
	);

    return undef unless $socket;

    $socket->autoflush(1);

    my $inQueue  = new ThreadQueue();
    my $outQueue = new ThreadQueue();

    my $self = {
	_inQueue  => $inQueue,
	_outQueue => $outQueue,
	_socket   => $socket,
	_host     => $host,
	_port     => $port
    };

    bless( $self, $class );
    threads->new('socketIO', $self)->detach();

    return $self;
}

sub send {
    my ( $self, $item ) = @_;
    $self->{_inQueue}->enqueue($item);
    return;
}

sub socketIO {
    my ( $self ) = @_;

    my $host     = $self->{_host};
    my $socket   = $self->{_socket};
    my $inQueue  = $self->{_inQueue};
    my $outQueue = $self->{_outQueue};

    my $select = new IO::Select( $socket );

    while ( $select->can_read(0.25) ) {
	my $response = <$socket>;
	if ( !defined($response) ) {
	    last;
	}
	$outQueue->enqueue($response);
    }

    while ( my $item = $inQueue->dequeue() ) {
	if (!$item) {
	    threads->exit();
	    return;
	}
	chomp($item);
	$item = uc($item);
	if ( $item eq "END" || $item eq "QUIT" ) {
	    threads->exit();
	    return;
	}

	if ( $select->can_write(0.025) ) {
	    print $socket "$item\n";
	} else {
	    warn "Unable to communicate with server at $host\n";
	}

	while ( $select->can_read(0.5) ) {
	    my $response = <$socket>;
	    if ( !defined($response) ) {
		last;
	    }
	    $outQueue->enqueue($response);
	}

	$outQueue->enqueue(undef);

    }
    return;
}

sub read {
    my ($self, $timeout) = @_;

    my $queue = $self->{_outQueue};

    while ( my $item = $queue->test($timeout) ) {
	return $item;
    }
    return undef;
}

sub close {
    my ( $self ) = @_;
    $self->{_socket}->close();
    $self->{_socket} = undef;
    $self->{_queue}  = undef;

    return undef;
}

return 1;
