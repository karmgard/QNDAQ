package daqChat;

use strict;
use warnings;

use Time::HiRes qw(usleep);

use IO::Socket;
use IO::Select;

use threads;
use threads::shared;

use QN::ThreadPool;
use QN::ThreadQueue;
use QN::ipFilter;

my $CRLF = "\015\012";  # \r\n
my $CR   = "\015";      # \r
my $LF   = "\012";      # \n

my $chatport;
my $crilSw;
my $filter;

my $password;
my $verbose = 0;
my $cril    = 0;

my $continue : shared = 1;

sub start {
    my ( $class, $vrbs, $passwd, $chtport,
	 $workers, $maxClnt, $crilsw, %lists ) = @_;

    $chatport = $chtport;

    $filter = new ipFilter(%lists);

    if ( $vrbs ) {
	$verbose = 1;
    }

    if ( $passwd ) {
	$password = $passwd;
    }

    if ( $crilsw ) {
	$cril = 1;
    }

    my $self = {
	_verbose  => $verbose
    };

    bless($self, $class);

    # Chat server to embed in the web page (on port 8888 by default)
    my $chat;
    if ( $chtport > 1023 ) {
	$chat = 
	    $self->startChatServerThread($chtport,$crilsw,
					 $workers,$maxClnt,$verbose);
    }
    $self->{_chatThread}  = $chat if $chat || undef;

    return $self;
}

sub running {
    #sleep 1;
    usleep(100000);
    return $continue;
}

sub stop {
    my ($self) = @_;
    if ( $self->{_verbose} ) {
	print "Stopping chat server\n";
    }

    if ( $self->{_chatThread} ) {
#	$self->{_chatThread}->kill('STOP');
	{
	    lock($continue);
	    $continue = 0;
	}
	$self->{_chatThread}->join();
    }

    undef $self;

    return 0;
}

#----------------------------------------------------------------#
#   Set up a chat server that can be embedded in the web page    #
#----------------------------------------------------------------#
sub startChatServerThread {
    my ( $self, $port, $cril, $workers, $maxClients, $verbose ) = @_;

    if ( !defined($verbose) ) {
	$verbose = 0;
    }

    if ( !defined($cril) ) {
	$cril = 0;
    }

    if ( !defined($workers) ) {
	$workers = 4;
    }

    if ( !defined($maxClients) ) {
	$maxClients = 25;
    }

    if ( !defined($port) ) {
	$port = 8888;
    }

    my $chatThread = threads->new('chatServer', $self,
				  $port, $cril, $workers, $maxClients, $verbose);

    return $chatThread if $chatThread || undef;
}

# Output queue
my $queue;

# Thread shared: table for connected clients
my $cTable    = &share({});
my $qTable    = &share({});
my $nickNames = &share({});
 
my $cLock : shared;
my $qLock : shared;
my $nLock : shared;

sub chatServer {
    my ( $self, $port, $cril, $workers, $maxClients, $verbose ) = @_;

    if ( !defined($verbose) ) {
	$verbose = 0;
    }
    share($verbose);

    if ( !defined($cril) ) {
	$cril = 0;
    }
    share($cril);

    if ( !defined($workers) ) {
	$workers = 4;
    }

    if ( !defined($maxClients) ) {
	$maxClients = 25;
    }

    if ( !defined($port) ) {
	$port = 8888;
    }

    # Make sure the worker threads are good
    $workers = ($workers >= 1) ? $workers : 1;
    $maxClients = ($maxClients>SOMAXCONN-2) ? SOMAXCONN-2 : $maxClients;

    $SIG{'INT'} = $SIG{'TERM'} = $SIG{'STOP'} =
	sub { lock $continue; $continue = 0; return; };

    # Thread queue
    $queue  = new ThreadQueue();

    # Thread pool to handle client reads in parallel
    my $thPool = new ThreadPool($workers,$workers,\&readClient,$verbose);

    # New thread that broadcasts client input
    threads->new("broadcast")->detach();

    # create the listen socket
    my $listenSocket = new IO::Socket::INET(
	LocalPort  => $port,
	Listen     => $maxClients+2,
	Proto      => 'tcp',
	Reuse      => 1
	);

    # Make sure bind() worked
    die "socket: $@\n" unless $listenSocket;

    # Announce our readiness
    if ( $verbose ) {
	print threads->tid() . " Started up with $workers threads\n";
	print "Ready. Waiting for connections ($maxClients max) on $port\n";
    }

    my $readable = new IO::Select();
    $readable->add( $listenSocket );

    my %connections = ();
    my $number_of_clients = 0;

    while ( $continue ) {
    
	# Wait for connections and readable clients
	my ($read) = IO::Select->select( $readable, undef, undef, 0.5 );

	# scan the client table for deleted entries
	{
	    lock( $cLock );
	    lock( $nLock );
	    while ( my ($key,$value) = each(%$cTable) ) {
		if ( $value == 0 ) {

		    # This client closed up and went away
		    my $conn = $connections{$key};

		    if ( !defined($conn) ) {
			warn "Undefined connection $key\n";
		    }

		    $readable->remove($conn) if  $conn;
		    $conn->close() if $conn;
		    delete($connections{$key});
		    delete($cTable->{$key});
		    delete($nickNames->{$key});
		    $number_of_clients--;

		}

	    } # End while ( each )

	} # End anonymous lock-block

	foreach my $sockH (@$read) {

	    # If we've arrived here before we can even start
	    # reading the client, an entry should exists in 
	    # the queue... so skip this loop since we've already
	    # dealt with it.
#	    my $key = fileno($sockH) if $sockH;
#	    if ( $key ) {
#		next if exists $qTable->{$key};
#	    }

	    if ( $sockH == $listenSocket ) {   # If this is the server....

		my $connection = $listenSocket->accept();

		# See if we're allowed to talk to this one
		my $ip = join( ".", unpack('C4', $connection->peeraddr) );
		if ( !$filter->filter($ip) ) {
		    close($sockH);
		    next;
		}

		if ( $number_of_clients >= $maxClients ) {
		    print $connection "Server is maxed out.$CRLF";
		    print $connection "Please try again later$CRLF";
		    $connection->close();
		    next;
		}

		if ( $verbose ) {
		    print "Accepted new connection " . 
			fileno($connection) . "\n";
		}
		$number_of_clients++;

		$connection->autoflush(1);

		if ( $^O =~ /MSWin32/ ) {
		    my $numbytes = 1;
		    ioctl( $connection, 0x8004667e, \\$numbytes ) || die $!;
		} else {
		    $connection->blocking(0);
		}

		# Add this client to the table
		{
		    lock $cLock;
		    $cTable->{fileno($connection)} = 5;
		}

		if ( $password ) {
		    $connection->write("Please enter the password$CRLF");
		    lock($cLock);
		    $cTable->{fileno($connection)} = -1;
		} else {
		    my $welcome = 
			"Welcome to DAQ Chat "; #$CRLF";
		    if ( !$cril ) {
			$welcome .= "(set a nickname with /nick <new>)$CRLF";
		    } else {
			$welcome .= $CRLF;
		    }
		    $connection->write($welcome);
		}

		{
		    lock($nLock);
		    $nickNames->{fileno($connection)} = $ip;
		}

		# Add the new guy to our selection
		# and store the connection so we can
		# retrieve and close it later
		$readable->add($connection);
		$connections{fileno($connection)} = $connection;

		# Tell everyone else that we arrived
		if ( !$password ) {
		    $queue->enqueue("$ip:logged in");
		}

	    } else {                           # A client is talking

#		my $key = fileno($sockH);
#		if ( $key ) {
#		    next unless !exists $qTable->{$key};
#		}

		if ( defined(fileno($sockH)) ) {

		    if ( $verbose ) {
			print "Enqueueing " . fileno($sockH) . "\n";
		    }

		    $thPool->enqueue( fileno($sockH) );
		    {
			lock($qLock);
			$qTable->{fileno($sockH)} = 1;
		    }
		}
	    }
	    
	} # end foreach ( my $sockH ... )

	usleep(25000);

    } # End while ( 1 )

    if ( $verbose ) {
	print "Server shutting down\n";
    }

    # Close the pool, the listener and exit gracefully
    $thPool->close();
    $queue->enqueue(undef);
    close $listenSocket;

    return 0;

}

#-----------------------------------------#
#           Subroutines & threads         #
#-----------------------------------------#
sub readClient {
    my ($pool) = @_;
    
    if ( $verbose ) {
	print "Client handler #" . threads->tid() . " starting up\n";
    }

    while ( my $handle = $pool->dequeue() ) {

	if ( !$handle ) {
	    last;
	}

	if ( $verbose ) {
	    print "$handle is talking to " . threads->tid() . 
		" with state " . $cTable->{$handle} . "\n";
	}

	# Duplicate the filehandle and do a single read on the client
	open( my $client, "+<&=", $handle );

	# Set client to autoflush
	$client->autoflush(1);

	# Take in what the client has to say
	my $inbuff = "";
	my $isActive;
	while ( $inbuff !~ /$CR|$LF|$CRLF/ ) {
	    $isActive = $client->sysread( $inbuff, 32, length($inbuff) );

	    if ( !defined($isActive) ) {
		usleep(25000);
	    } elsif ( $isActive == 0 ) {
		$inbuff = "CLOSE$CR";
		last;
	    }
	}

	$inbuff =~ s/$CR|$LF//g;

	if ( uc($inbuff) eq "CLOSE" ) {
	    if ( $verbose ) { print "$handle closed connection\n";}

	    $queue->enqueue("$handle:logged out");

	    lock( $cLock );
	    $cTable->{$handle} = 0;

	} elsif ( uc($inbuff) eq "DONE" ) {

	    lock($continue);
	    $continue = 0;
	    lock( $cLock );
	    $cTable->{$handle} = 0;

	} elsif ( $cTable->{$handle} == -1 ) {
	    # Password required to get in
	    if ( $inbuff =~ /$password/i ) {
		my $welcome = 
		    "Welcome to DAQ Chat ";
		if ( !$cril ) {
		    $welcome .= "(set a nickname with /nick <new>)$CRLF";
		} else {
		    $welcome .= $CRLF;
		}
		
		$client->write($welcome);

		my $ip = $nickNames->{$handle};
		$queue->enqueue("$ip: logged in");

		lock($cLock);
		$cTable->{$handle} = 5;
		
	    } else {    # Invalid password... kick 'em out
		lock($cLock);
		$cTable->{$handle} = 0;
	    }

	} elsif ( $inbuff =~ /\/nick/ ) {

	    $inbuff =~ s/\/nick//g;
	    $inbuff =~ s/$CR|$LF//g;
	    $inbuff =~ s/\s//g;

	    if ( $verbose ) {
		print "Changing nickname for " . $nickNames->{$handle};
	    }

	    {
		lock($nLock);
		$nickNames->{$handle} = $inbuff;
	    }

	    $queue->enqueue("$handle:I changed my name from ".$nickNames->{$handle});
	    
	    if ( $verbose ) {
		print " to " . $nickNames->{$handle} . "\n";
	    }

	} else {
	    $queue->enqueue("$handle:$inbuff");
	}

	if ( $verbose ) {
	    print threads->tid() . " is done with " . fileno($client) . "\n";
	}

	# Close this handle
	close($client);

	{
	    lock($qLock);
	    delete( $qTable->{$handle} );
	}

    } # End while ( my $handle ... )

    if ( $verbose ) {
	print "clientRead " . threads->tid() . " cosing down\n";
    }

    return threads->tid();
}

sub broadcast {
    if ( $verbose ) {
	print threads->tid() . " started as broadcaster\n";
    }

    while (1) {

	# Block 'til there's something in the queue
	while ( my $item = $queue->dequeue() ) {
	    if ( !defined($item) ) {
		last;
	    }
	    my ($id,$data) = split(/:/,$item);

	    # Get the nick name of the user (if they've set one)
	    my $name = (defined($nickNames->{$id})) ? 
		$nickNames->{$id} : $id;

	    # Loop over the connected clients
	    {
		lock $cLock;
		while ( my ($key, $value) = each(%$cTable) ) {
		    # Send to each client except the originator
		    if ( $id ne $key && $value > 0 ) {
			if ( open(FH, ">&=", $key) ) {
			    print FH "$name says: $data$CRLF";
			    close(FH);
			} else {
			    lock( $cTable );
			    if ( $cTable->{$key} ) {
				print "Decrementing $key to ";
				$cTable->{$key}--;
				print $cTable->{$key} . "\n";
			    }
			} # End if (open) {} else {}
		    } # End if ( $id != $key
		} # End while ( each )
	    } # End anonymouse lock-block
	} # End while ( dequeue )
    } # End while(1)

    if ( $verbose ) {
	print " broadcaster shutting down\n";
    }

    return;
}

return 1;
