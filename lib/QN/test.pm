package QN::test;

use strict;
use warnings;

use IO::Select;
use Socket;

use threads;
use threads::shared;
use QN::ThreadQueue;

######################################################################
# A module's version number is stored in $ModuleName::VERSION; certain 
# forms of the "use" built-in depend on this variable being defined.
 
our $VERSION = '1.00';
 
# Inherit from the "Exporter" module which handles exporting functions.
# Most procedural modules make use of this.
use base 'Exporter';

# When the module is invoked, export, on request, the functions 
# in @EXPORT_OK into the namespace of the using code.
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(checkCmd cmdPriority cmdIsQuery);

##########################################################################

# Globals shared accross threads
my $command : shared;
my $cardQ = new ThreadQueue();
my $verbose = 0;

my $CRLF = "\015\012";
my $CR   = "\015";
my $LF   = "\012";

sub new {
    my ($class, $verbosity ) = @_;

    if ( $verbosity ) {
	$verbose = 1;
    }

    my $counter = 0;
    my $self = {
	_counter  => $counter,
	_streamer => undef,
	_SN       => 1234
    };

    bless $self, $class;
    return $self;
}

#-------------------------------------------#
# Cleanup and exit semi-gracefully          #
#-------------------------------------------#
sub shutdown {
    my ($self) = @_;
    if ( $self->{_streamer} ) {
	$cardQ->enqueue(undef);
	$self->{_streamer}->detach();
	$cardQ->cleanup();
    }

    # And undef the memory
    undef $self;

    return undef;
}

#-------------------------------------------#
# Init the streamer: Set up a socket pair   #
# for communication and send the streamer   #
# into the background as a thread (could as #
# well fork the streamer)                   #
#-------------------------------------------#
sub setupStream {
    my ($self) = @_;

    socketpair( cardSocket, serverSocket,
	    PF_UNIX, SOCK_STREAM, PF_UNSPEC) || die "socket: $!";
    select( (select(cardSocket),  $|=1)[0] );  # Set autoflush on both pipes
    select( (select(serverSocket), $|=1)[0] );

    $self->{_socket} = \*cardSocket;
    $self->{_streamer} = threads->new( 'stream', $self )->detach();
    return \*serverSocket;
}

#-------------------------------------------#
# Queue up a command for the card streamer  #
#-------------------------------------------#
sub submit {
    my ($self,$msgID,$command) = @_;
    my $sock = $self->{_socket};

    # If it's not a good command... don't 
    # waste any time. Just throw an error and bail
    if ( !&checkCmd($command) ) {
	print $sock "$msgID: Cmd??\nEOT\n";
	return -1;
    }

    # Put the command in the queue for processing
    $cardQ->enqueue($msgID.":".$command);
    return 0;
}

#-------------------------------------------#
# Sit and wait for a command. Then post it  #
# and stream each line of the response from #
# the card as it comes in. Meant to be run  #
# in the background as a fork or thread     #
#-------------------------------------------#
sub stream {
    my ($self) = @_;

    my $continue = 1;

    $SIG{'STOP'} = sub {
	$continue = 0;
	last;
    };

    my $sock = $self->{_socket};

    while ($continue) {
	my ($msgID,$command) = split(/:/,$cardQ->dequeue());

	if ( !$command || $command eq "END" ) {
	    $continue = 0;
	    last;
	}

	my $count = $self->{_counter}++;

	# Send a vapid response
	print $sock "$msgID:response #$count$CRLF";

	# All done... signal our caller that the stream is closed
	print $sock "$msgID:EOT$CRLF";

    } # End while ($continue)

    print $sock "EOT$CRLF";
    $command = undef;

    return 0;
}

sub checkCmd {
    my ( $command, $quickCheck ) = @_;
    return 1;
}

sub cmdPriority {
    my ($cmd) = @_;
    return 1;
}

sub cmdIsQuery {
    my ( $self ) = @_;
    return 1;
}

sub check {
    my ( $self ) = @_;
    return undef;
}

sub help {
    my ( $self, $msgID ) = @_;
    return "$msgID:No help for you!";
}

sub get_serial_number {
    my ( $self ) = @_;
    return $self->{_SN};
}

sub get_stat {
    my ( $self, $queue ) = @_;
    $queue->enqueue("stat:STAT");
    return;
}

sub status {
    my ( $self ) = @_;
    return "status|SN=" . $self->{_SN} . ",OK";
}

sub make_status_line {
    my ( $self ) = @_;
    return "status|SN=" . $self->{_SN} . ",OK";
}

sub start_status {
    my ( $self ) = @_;
    return;
}

sub stop_status {
    my ( $self ) = @_;
    return;
}

sub get_persistent_status {
    my ( $self ) = @_;
    return "status|SN=" . $self->{_SN} . ",OK";
}

sub settings_changed {
    my ( $self ) = @_;
    return 0;
}

return 1;
