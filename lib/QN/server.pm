package server;
#
#----------------------------------------------------------------#
#                                                                #
# Server class for the QuarkNet DAQ server. This implements      #
# the network server that receives input from clients, and the   #
# queue => cardServer => card => cardServer => client pipline    #
# for processing requests                                        #
#                                                                #
#----------------------------------------------------------------#
#
use strict;
use warnings;

use IO::Socket;
use IO::Select;

use Time::HiRes qw( usleep );

use threads;
use threads::shared;

use QN::ThreadQueue;
use QN::ThreadPool;
use QN::Client;
use QN::ipFilter;

use QN::daq qw(cmdIsQuery checkCmd cmdPriority);
#use QN::motor;

# Globals imported from options.pm
# The optional values are passed in as 
# $optRef (reference to a hash)
# during class construction in new()
my $OS;
my $system;
my $verbose;
my $continue;
my $idlength = 4;
my $daemon;
my $simulate;
my @daqcard;
my $password;
my $port;
my $filter;
my $cril;
my $motordev;
my %forwdlist;

# Queue for saving data in compressed forms
my $zipQueue = new ThreadQueue(); 

# Standard line terminators
my $CRLF = "\015\012";
my $CR   = "\015";
my $LF   = "\012";

# Variables that are shared amongst threads
share($continue);
share($verbose);

# Toggle for locking the DAQ by one client
my $locked : shared = 0;

# Lookup table for connected clients
my $clients_lock : shared;
my $clientTable = &share({});
my $msgTable    = &share({});
my $send_status : shared = 0;
my $stat_freq : shared = 30;

# Keep track of outstanding message IDs
# so that the assign ID routine can 
# keep them unique
my %activeID;
share(%activeID);

# Input/Output queues and the threads that deal with them
my $outputQueue;
my $sendThread;
my $dataThread;

my $motorQueue;
my $motorThread;
my $motor_current_status : shared = "no motor";

my @inputQueue = ();
share(@inputQueue);

# Shared card status & indexing
my %SNIndex = ();
my @SNReverseIndex = ();
share(%SNIndex);
share(@SNReverseIndex);

# Persistent status line for settings
# that don't change very often
my @settings_status = ();
share(@settings_status);

my @procThread = ();

my $threadPool;

sub new {
    my ($class, $optRef) = @_;

    # Assign the options from options.pm to our local copies
    $OS         = $optRef->{OS};
    $system     = $optRef->{system};
    $verbose    = $optRef->{verbose};
    $continue   = $optRef->{continu};
    $daemon     = $optRef->{daemon};
    $simulate   = $optRef->{simulate};
    $password   = $optRef->{password};
    $cril       = $optRef->{cril};
    $motordev   = $optRef->{motor};
    @daqcard    = @{$optRef->{daqcard}};

    $filter = new ipFilter( 
	(
	 'whitelist' => \@{$optRef->{whitelist}},
	 'blacklist' => \@{$optRef->{blacklist}}
	)
	);

    my @flist   = @{$optRef->{forwdlist}};
    for ( my $i=0; $i<=$#flist; $i++ ) {
	my ( $ip, $rport, $alias ) = split(/,/, $flist[$i]);

	if ( !$ip ) {
	    next;
	}

	if ( !$rport ) {
	    $rport = $optRef->{port};
	}

	if ( !$alias ) {
	    $alias = $ip;
	}

	$forwdlist{uc($alias)} = "$ip:$rport";
    }

    # Locals... out of scope when the class is constructed
    $port       = $optRef->{port};
    my $max     = $optRef->{maxclients};

    if ( $max > eval(SOMAXCONN - 2) ) {
	$max = eval(SOMAXCONN-2);
    }

    #-----------------------------------------------------------#
    #                  Main TCP Server                          #
    #-----------------------------------------------------------#
    my $proto = getprotobyname('tcp');
    my $socket = IO::Socket::INET->new (
	Proto     => $proto,
	LocalPort => $port,
	Listen    => $max,
	ReuseAddr => 1
	);
    die "Socket::INET::new failed: $!" unless defined $socket;

    my $self = {
	_socket      => $socket,
	_max_clients => $max
    };

    # Tell perl that it's all OK
    bless($self, $class);

    # What to do with a <CTRL>-c
    $SIG{'INT'} = $SIG{'TERM'} = sub { $self->serverShutDown; };

    return $self;
}

sub indexQueue {
    my ( $self ) = @_;
    my $client = new Client('localhost', $port);

    for ( my $i = 0; $i <= $#inputQueue; $i++ ) {
	$client->send("$i,SN");
	my $serial = $client->read();
	print "$i => $serial\n";
    }

    return 0;

}

sub startQueues {
    my ( $self ) = @_;

    # Various shared variables
    $outputQueue = ThreadQueue->new();              # Output queue
    $sendThread  = threads->new('sendResponse');
    $dataThread  = threads->new('saveZipData');

    for ( my $i=0; $i<=$#daqcard; $i++ ) {          # Input queues, 1/card
	push( @inputQueue, ThreadQueue->new() );
	push( @procThread, threads->new('procQueue', $i) );
    }

    # Crank up the motor thread & queue if we're running a CRiL
    if ( $cril && -c $motordev ) {
	$motorQueue = ThreadQueue->new();
	$motorThread = threads->new('motorControl', $motordev, $verbose);
    }

    return 1 if ( $#procThread>-1 && $sendThread && $dataThread ) || undef;
}

my %frwdQueue;
sub startClients {
    my ( $self ) = @_;
    while ( my ($client,$ip) = each(%forwdlist) ) {
	my ($host,$port) = split(/:/, $ip);
	$frwdQueue{$client} = new ThreadQueue();
	threads->new('forward', $frwdQueue{$client}, $client, $host, $port)->detach();
    }
    return;
}

sub startThreadPool {
    my ( $self, $workers, $maxclients, $verbose ) = @_;
    $maxclients = ( defined($maxclients) ) ? $maxclients : eval(3*$workers);
    $verbose    = ( defined($verbose) )    ? $verbose    : 0;

    $threadPool = new ThreadPool($workers, $maxclients, \&clientHandler, $verbose);
    return 1 if ( $threadPool ) || undef;
}

sub startDataSaverThread {
    my ( $self ) = @_;
    my $dataSaver = threads->new('saveZipData');
    return $dataSaver if $dataSaver || undef;
}

sub mainLoop {
    my ( $self ) = @_;

    my $readable = new IO::Select();

    # The main socket & the terminal had better be readable
    $readable->add($self->{_socket}) || die "Unable to read from socket! $@\n";

    # The M$ console is badly broken. So don't even try to read
    # from it as select doesn't work on files or pipes. If we
    # added STDIN to $readable the server would stop & block
    # on the first pass trying to read STDIN. On MSWin32 systems
    # the only way to interact with the server is to telnet in
    # from localhost
    if ( $OS !~ /MSWin32/ && !$daemon ) {
	$readable->add(\*STDIN) || die "Unable to read from STDIN! $@\n";
    }

    my $number_of_clients = 0;
    my %connections = ();           # Reverse lookup tables
    my %clients     = ();

    #
    #--------------------------------------------------------------------#
    #  Server loop... wait for connections & dispatch the client thread  #
    #--------------------------------------------------------------------#
    #
    while ( $continue ) {   # Loop forever... exit condition comes later

	# See if any clients are trying to connect
	# Timeout every quarter second to handle 
	# routine tasks
	my @read = $readable->can_read(0.25);

	foreach my $rh (@read) {

	    #------------------------------------------------#
	    # Take server state commands directly from STDIN #
	    #------------------------------------------------#
	    if ( $rh == \*STDIN ) {
		my $cmd = <STDIN>;
		chomp($cmd);
		$cmd = uc($cmd);

		print "Got $cmd from STDIN\n";

		# All done... wrap it up
		if ( $cmd eq "DONE" ) {
		    $self->serverShutDown();

		# Change the password
		} elsif ( $cmd =~ /PW|PASSWORD/ ) {
		    $cmd =~ s/PW |PASSWORD //;
		    $password = lc($cmd);
		    if ( $verbose ) {
			print "Setting password to $password\n";
		    }

		# Server settings stuff for testing    
		} elsif ( $cmd =~ /^VB|^VERBOSE/ ) {
		    $verbose = !$verbose;

		} elsif ( $cmd =~ /^QU|^QUEUE/ ) {
		    lock(@inputQueue);
		    for ( my $i=0; $i<=$#inputQueue; $i++ ) {
			for ( my $j=0; $j<$inputQueue[$i]->pending(); $j++ ) {
			    print $inputQueue[$i]->peek($j) . "\n";
			}
		    }
		}

	    } elsif ( $rh == $self->{_socket} ) {  # On the main socket... 
		my $ns = $rh->accept();            # add a new connection

		# Get the client IP address from the socket glob
		my $ip = join( ".", unpack('C4', $ns->peeraddr) );

		# If the server already has all the connections 
		# it can handle (defined by max-client switch)
		# Send an error message and close this connection
		if ( $number_of_clients >= $self->{_max_clients} ) {
		    print $ns "Server is maxed out. Please try again later$CRLF";
		    close($ns);
		    next;
		}

		if ( $verbose ) {
		    print "Request from $ip\n";
		}

		# Check the filter(s) to see if we should accept this client
		if ( !$filter->filter($ip) ) {
		    close($ns);
		    next;
		}

		if ( $verbose ) {
		    print "Got connect\n";
		}

		# Get a unique 6 character ID
		my $clientID = &requestID( 6 );

		# Increment the client counter
		$number_of_clients++;

		# Add the client to the output pool
		{
		    lock $clients_lock;

		    $clientTable->{$clientID} = &share({});
		    $clientTable->{$clientID}->{'state'}     = 
			($password) ? 'password' : 'open';
		    $clientTable->{$clientID}->{'haslock'}   = 0;
		    $clientTable->{$clientID}->{'broadcast'} = 1;
		    $clientTable->{$clientID}->{'sendmsgid'} = 0;
		    $clientTable->{$clientID}->{'rcvstatus'} = 0;
		    $clientTable->{$clientID}->{'fileHandl'} = fileno($ns);
		    $clientTable->{$clientID}->{'ipaddress'} = $ip;

		    # Set the connection state
		    $ns->autoflush(1);
		    if ( $OS =~ /MSWin32/ ) {
			my $nonblocking = 1;
			ioctl($ns, 0x8004667e, \\$nonblocking) || die $!;
		    } else {
			$ns->blocking(0);
		    }

		} # End anonymous lock-block for client_lock

		# Save this connection so it doesn't close when we descope
		# and we'll be notified when it raises SIGIO
		$connections{fileno($ns)} = $ns;
		$clients{fileno($ns)} = $clientID;
		$readable->add($ns);

		if ( $password ) {
		    print $ns "Please enter password\r\n";
		} else {
		    # Send a welcome message
		    print $ns "Welcome to the QuarkNet DAQ Server\r\n";
		}

		if ( $verbose ) {
		    print "Awaiting new connection\n";
		}

	    } else {          # End elsif ( $rh == $self->{_socket} )
		# OK... must be a SIGIO on an existing connection
		# Dispatch it into the threadpool for reading if it
		# isn't already being handled

		my $clientID = $clients{fileno($rh)};
		my $state = $clientTable->{$clientID}->{"state"};

		if ( $state eq "open" || $state eq "password" ) {
		    $threadPool->enqueue($clientID);
		    usleep(1000);  # Pause a moment so the pool can pick us up
		}
	    }

	} # End of foreach my $rh (@$read) {

	# Periodically check the status of the clients in the pool
	foreach my $clientID ( keys(%$clientTable) ) { 
	    my $state = uc($clientTable->{$clientID}->{'state'});

	    if ( defined($state) && uc($state) eq "CLOSE" ) {
		# Remove this client
		my $handle = $clientTable->{$clientID}->{'fileHandl'};

		# Close up the connection
		my $connection = $connections{$handle};

		$readable->remove($connection);
		$connection->close();

		# See if this client currently has a lock on the DAQ
		if ( $clientTable->{$clientID}->{'haslock'} ) {
		    $locked = 0;
		}

		# And if this client was receiving status lines
		if ( $clientTable->{$clientID}->{'rcvstatus'} ) {
		    $send_status--;
		}

		lock($clients_lock);
		delete $clientTable->{$clientID};
		delete $connections{$handle};
		delete $clients{$handle};

		# And decrement the number of clients
		$number_of_clients--;

		lock(%activeID);
		delete $activeID{$clientID};

	    } elsif ( defined($state) && uc($state) eq "DONE" ) {
		$self->serverShutDown();
	    }
	}

    } # End of while ( $continue ) -- main server loop 

    return;
} # End of sub mainLoop

#
#-----------------------------------------------------------#
#      Subroutines, worker-threads, and riff-raff.          #
#-----------------------------------------------------------#
#

#-----------------------------------------------------------#
#           Worker thread to handle client input            #
#-----------------------------------------------------------#
sub clientHandler {
    my ( $pool ) = @_;
 
    if ( $verbose ) {
	print "Starting up client thread " . threads->tid() . "\n";
    }

    while ( my $clientID = $pool->dequeue() ) {

	if ( !defined($clientID) ) {
	    # All done... close down
	    last;
	}

	my $state = $clientTable->{$clientID}->{'state'};

	# Flag the client as being in a readable state
	{
	    lock($clients_lock);
	    $clientTable->{$clientID}->{"state"} = "read";
	}

	# And increment our active thread counter
	{
	    lock($ThreadPool::active);
	    $ThreadPool::active++;
	}

	my $sd = $clientTable->{$clientID}->{'fileHandl'};
	my $ip = $clientTable->{$clientID}->{'ipaddress'};

	# use fdopen to duplicate the filehandle
	open( my $rh, "+<&=", $sd );
	if ( !$rh ) {
	    warn "Unable to read from $ip! $@\n";
	    lock($clients_lock);
	    $clientTable->{$clientID}->{"state"} = "open";
	    next;
	}

        #---------------------------------------------------------------------#
	# If we're using a password... demand it here
	if ( $state eq "password" && $password ) {

	    # Stall counter... throw a timeout if no characters in 10s
	    my $sleepy = 25000;
	    my $STALL_TIMEOUT = 10000000;
	    my $timer = 0;

	    # Take in what the client has to say
	    my $pwdchk = "";
	    my $isActive;
	    while ( $pwdchk !~ /$CR|$LF|$CRLF/ ) {
		$isActive = $rh->sysread( $pwdchk, 32, length($pwdchk) );

		if ( !defined($isActive) ) {
		    usleep($sleepy);
		    $timer += $sleepy;

		    if ( $timer >= $STALL_TIMEOUT ) {
			$pwdchk = "CLOSE$CR";
			print $rh $CRLF . "Timeout$CRLF\n";
			last;
		    }

		} elsif ( $isActive == 0 ) {
		    $pwdchk = "CLOSE$CR";
		    last;
		} else {
		    $timer = 0;
		}
	    }

	    $pwdchk =~ s/$CR|$LF//g;

	    if ( $pwdchk ne $password ) {
		if ( $verbose ) {
		    print "Incorrect password from $ip\n";
		}
		close($rh);
		lock($clients_lock);
		$clientTable->{$clientID}->{"state"} = "close";
		next;

	    } else {
		# Send a welcome message
		$clientTable->{$clientID}->{"state"} = "open";
		print $rh "Welcome to the QuarkNet DAQ Server\r\n";
	    }

	    # We've dealt with the password... cycle back for the next job
	    lock($clients_lock);
	    $clientTable->{$clientID}->{"state"} = "open";
	    next;

	} else {
	    lock($clients_lock);
	    $clientTable->{$clientID}->{'state'} = "read";
	}
        #---------------------------------------------------------------------#

	# Pieces of the message format
	my ($card, $frwd, $cmd, $msgID, $priority);

	# I *hope* this means read (at most) 64 bytes from the 
	# socket into $inbuff in 16 byte chunks. A valient and 
	# probably fultile effort to nip buffer overflows in the bud.
	#
	# The goofy sysread in the while loop is a workaround for M$
	# of course. M$ can't seem to multiplex sockets if they're 
	# in blocking mode, and if they're in non-block mode then
	# the select call always returns ready. Which is really no
	# help at all. So we have to roll our own. So this loop 
	# will read/sleep/read/sleep... until a) it gets an EOL 
	# (\r or \n), 64 bytes have been input, or the client 
	# goes away. $isAlive returns undef on <nothing to read>, 
	# <number of bytes> read on a successful read, or <0> 
	# when the client closes the connection without saying bye
	my $inbuff = "";

	# Stall counter... throw a timeout if no characters in 10s
	my $sleepy = 25000;
	my $STALL_TIMEOUT = 10000000;
	my $timer = 0;

	while ( $inbuff !~ /$CR|$LF|$CRLF/ && length( $inbuff ) < 64 ) {

	    if ( $clientTable->{$clientID}->{'state'} ne "read" ) {
		last;
	    }

	    my $isAlive = $rh->sysread( $inbuff, 16, length( $inbuff ) );

	    if ( !defined($isAlive) ) {   # Tried to read... got bupkis
		usleep($sleepy);
		$timer += $sleepy;

		if ( $timer >= $STALL_TIMEOUT ) {
		    print $rh $CR . "Timeout$CRLF";
		    lock($clients_lock);
		    $clientTable->{$clientID}->{'state'} = "timeout";
		    $inbuff = "";
		    last;
		}

	    } elsif ( $isAlive == 0 ) {   # Got a response: dead connection
		if ( $verbose ) {
		    print "Lost connection with $ip\n";
		}
		{
		    lock($clients_lock);
		    $clientTable->{$clientID}->{'state'} = "close";
		    last;
		}
	    } else {
		$timer = 0;
	    }
	}
	if ( $clientTable->{$clientID}->{'state'} eq "close" ) {
	    next;
	}

	if ( $clientTable->{$clientID}->{'state'} eq "timeout" ) {
	    lock($clients_lock);
	    $clientTable->{$clientID}->{'state'} = "open";
	    next;
	}

	# OK... our infinite read loop has ended... we probably have
	# a request from this client. See if we can process it

	# Massage the input so it's easier to deal with
	$inbuff =~ s/$CR|$LF|$CRLF//g;

	# Make sure there's actually something there
	# If not... throw an error back to the client
	# and bail
	if ( length($inbuff) ) {
	    $inbuff = trim($inbuff);
	}
	if ( !length($inbuff) ) {
	    my $msgID = &requestID($idlength);
	    $outputQueue->enqueue("$msgID:enqueued");
	    $outputQueue->enqueue("$msgID: Cmd ??");
	    $outputQueue->enqueue("$msgID:complete");

	    lock($clients_lock);
	    $clientTable->{$clientID}->{"state"} = "open";

	    lock(%activeID);
	    delete $activeID{$msgID};

	    next;
	}

	# Parse the command for special signifiers...
	if ( $inbuff =~ /,/ ) {
	    ($card,$inbuff) = split(/,/, $inbuff);

	    $card =~ s/\s+//g;
	    if ( $card !~ /a|all/i ) {

		if ( $card < 1000 ) {
		    if ( $card > $#inputQueue ) {
			$card = $#inputQueue;
		    } elsif ( $card < 0 ) {
			$card = 0;
		    }
		} else {
		    if ( exists $SNIndex{$card} ) {
			$card = $SNIndex{$card};
		    } else {
			my $msgID = &requestID($idlength);
			$outputQueue->enqueue("$msgID:enqueued");
			$outputQueue->enqueue("$msgID:No such card");
			$outputQueue->enqueue("$msgID:complete");
			next;
		    }
		}
	    }
	    if ( $verbose ) {
		print "Got a DAQ card tag of $card\n";
	    }
	} else {
	    $card = 0;
	}

	if ( $inbuff =~ /\\/ ) {
	    ($inbuff, $frwd) = split(/\\/, $inbuff);

	    $frwd =~ s/\s+//g;
	    $frwd = uc($frwd);

	    if ( $frwd =~ /a|all/i ) {
		if ( $verbose ) {
		    print "Forwarding $inbuff to everyone\n";
		}
	    } elsif ( !defined( $forwdlist{$frwd} ) ) {
		$frwd = undef;
	    } elsif ( $verbose ) {
		print "Forwarding command $inbuff to $forwdlist{$frwd}\n";
	    }
	}

	# Make it case insensitive for the user
	$cmd = uc( $inbuff );

	if ( $verbose ) {
	    print "received $cmd from $ip\n";
	}

	# Process special commands that have
	# nothing to do with the DAQ card
	if ( $cmd =~ /^CL/ ) {
	    if ( $verbose ) {
		print "$ip closed the connection\n";
	    }
	    {
		lock($clients_lock);
		$clientTable->{$clientID}->{'state'} = "close";
	    }
	    next;
	}

	# Assign a unique ID to this request
	$msgID = &requestID( $idlength );
	{
	    lock($clients_lock);
	    $msgTable->{$msgID} = $clientID;
	}

	# We've got input from the client
	# See if we're accepting it
	if ( $locked && !$clientTable->{$clientID}->{'haslock'} ) {

	    if ( $ip ne "127.0.0.1" && !cmdIsQuery($cmd) ) {
		# Throw a warning back to this client only
		print $rh " DAQ is locked$CRLF";
		lock($clients_lock);
		$clientTable->{$clientID}->{"state"} = "open";
		next;
	    }
	}

	#------------------------------------------------------#
	# We have a command, the DAQ is available, deal with it#
	#------------------------------------------------------#
	# Only allow these from someone connected on localhost #
	#                                                      #
	if ( $cmd eq "DONE" ) { # Close the server and exit
	    if ( $ip eq "127.0.0.1" ) {
		lock($clients_lock);
		$clientTable->{$clientID}->{'state'} = "done";
		next;
	    }

	} elsif ( $cmd =~ /^VB|^VERBOSE/ ) {  # stuff for testing
	    if ( $ip eq "127.0.0.1" ) {
		$verbose = !$verbose;
	    }

	} elsif ( $cmd =~ /^QUE/ ) {
	    if ( $ip eq "127.0.0.1" ) {
		print "Dumpping batched queue\n";
		lock(@inputQueue);
		for ( my $i=0; $i<=$#inputQueue; $i++ ) {
		    for ( my $j=0; $j<$inputQueue[$i]->pending(); $j++ ) {
			print $inputQueue[$i]->peek($j) . "\n";
		    }
		}
		lock($outputQueue);
		for ( my $i=0; $i<$outputQueue->pending(); $i++ ) {
		    print $outputQueue->peek($i) . "\n";
		}
	    }
	    
	} elsif ( $cmd =~ /^F_UNLOCK$/ ) {
	    if ( $ip eq "127.0.0.1" ) {
		if ( $locked ) {
		    lock($clients_lock);
		    $locked = 0;
		    
		    while ( my ($clientID,$value) = each(%$clientTable) ) {
			$clientTable->{$clientID}->{'haslock'} = 0;
		    }
		    $outputQueue->enqueue( "$msgID:enqueued" );
		    $outputQueue->enqueue( "$msgID: DAQ unlock forced" );
		    $outputQueue->enqueue( "$msgID:complete" );
		}
	    } else {
		warn "$ip is trying to force an unlock!\n";
	    }
	#                                                      #
	#------------------------------------------------------#
	#                  Per client options                  #
	} elsif ( $cmd =~ /^BC/ ) {
	    if ( $cmd =~ /^BC (\d)/ ) {
		if ( defined($1) ) {
		    my $bc = $1;
		    $bc = ( $bc > 1 ) ? 1 : $bc;
		    $bc = ( $bc < 0 ) ? 0 : $bc;

		    $clientTable->{$clientID}->{'broadcast'} = $bc;
		}
	    }
	    print $rh "BC=";
	    print $rh ($clientTable->{$clientID}->{'broadcast'}) ? "true" : "false";
	    print $rh $CRLF;

	} elsif ( $cmd =~ /^SS.*/ ) {
	    if ( $cmd =~ /^SS (\d+)/ ) {
		if ( defined($1) ) {
		    my $rs = $1;
		    
                    $rs = ( $rs > 1 ) ? 1 : $rs;
                    $rs = ( $rs < 0 ) ? 0 : $rs;

		    if ( $rs ) {
			$send_status++;			    
		    } else {
			$send_status--;
			if ( $send_status < 0 ) {
			    $send_status = 0;
			}
		    }

		    $clientTable->{$clientID}->{'rcvstatus'} = $rs;
		    print $rh "SS=";
		    print $rh ($rs) ? "true" : "false";
		    print $rh $CRLF;

		    if ( $rs ) {
			foreach my $status (@settings_status) {
			    $outputQueue->enqueue("stat:$status");
			}
			foreach my $queue (@inputQueue) {
			    $queue->enqueue("10:stat:ST");
			}
		    }
		}
	    } else {
		print $rh "SS=";
		print $rh ($clientTable->{$clientID}->{'rcvstatus'}) ? "true" : "false";
		print $rh $CRLF;
	    }

	} elsif ( $cmd =~ /^SI|SENDID/ ) {
	    if ( $cmd =~ /(\d)/ ) {
		if ( defined($1) ) {
		    my $ss = $1;
		    if ($ss > 2) {$ss = 2;} elsif ($ss<0) {$ss=0;}
		    if ( $verbose ) {
			print "$ip set SI=$ss\n";
		    }
		    $clientTable->{$clientID}->{'sendmsgid'} = $ss;
		} else {
		    $clientTable->{$clientID}->{'sendmsgid'} = 
			!$clientTable->{$clientID}->{'sendmsgid'};
		}
		
	    } 
	    print $rh "SI=" . $clientTable->{$clientID}->{'sendmsgid'} . $CRLF;

	#------------------------------------------------------#
	#             Save this run to a disk file             #
	#                                                      #
	} elsif ( $cmd =~ /SV/ ) {
	    $cmd =~ /.*SV\s(.*)/;

	    if ( $clientTable->{$clientID}->{'sendmsgid'} == 2 ) {
		print $rh "$msgID:enqueued$CRLF";
	    } elsif ( $clientTable->{$clientID}->{'sendmsgid'} == 1 ) {
		print $rh "enqueued$CRLF";
	    }

	    my $name = (defined($1)) ? "$1-" : undef;
	    if ( !$name ) {

		if ( defined($clientTable->{$clientID}->{'outfile'}) ) {
		    my $file = $clientTable->{$clientID}->{'outfile'};
		    ($file) = reverse(split("\/", $file) );
		    if ( $clientTable->{$clientID}->{'sendmsgid'} == 2 ) {
			print $rh "$msgID:";
		    }
		    print $rh "$file$CRLF";
		} else {
		    if ( $clientTable->{$clientID}->{'sendmsgid'} == 2 ) {
			print $rh "$msgID:";
		    }
		    print $rh "not saving$CRLF";
		}

	    } elsif ( $name =~ /CLOSE/ ) {
		my $file = $clientTable->{$clientID}->{'outfile'};
		($file) = reverse(split("\/", $file) );
		$zipQueue->enqueue("$clientID|close");

		delete $clientTable->{$clientID}->{'outfile'};

		if ( $clientTable->{$clientID}->{'sendmsgid'} == 2 ) {
		    print $rh "$msgID: $file closed$CRLF";
		} else {
		    print $rh "$file closed$CRLF";
		}

	    } else {
		my ($sec,$min,$hour,$day,$month,$year) = localtime(time);
		$year  -= 100;
		$month += 1;
	    
		my $dataFile;
		if ( $cril ) {
		    $dataFile = sprintf("%s/cril-%s%02i%02i%02i%02i%02i%02i.zip",
					$ENV{'OUTDIR'}, lc($name), 
				       $year, $month, $day, 
				       $hour, $min, $sec);
		} else {
		    $dataFile = sprintf("%s/%scrd-%02i%02i%02i%02i%02i%02i.zip",
				       $ENV{'OUTDIR'}, lc($name), 
				       $year, $month, $day, 
				       $hour, $min, $sec);
		}
		if ( !$clientTable->{$clientID}->{'outfile'} ) {
		    $clientTable->{$clientID}->{'outfile'} = $dataFile;
		    $zipQueue->enqueue("$clientID|create");
		} else {   # They're changing files on us...
		    my $file = $clientTable->{$clientID}->{'outfile'};
		    $zipQueue->enqueue("$clientID|close");

		    delete $clientTable->{$clientID}->{'outfile'};

		    if ( $clientTable->{$clientID}->{'sendmsgid'} == 2 ) {
			print $rh "$msgID: $file closed$CRLF";
		    } else {
			print $rh "$file closed$CRLF";
		    }
		    $clientTable->{$clientID}->{'outfile'} = $dataFile;
		    $zipQueue->enqueue("$clientID|create");
		}
  
		my ($fileName) = reverse(split("\/", $dataFile) );
		if ( $clientTable->{$clientID}->{'sendmsgid'} == 2 ) {
		    print $rh "$msgID: Saving data to $fileName$CRLF";
		} else {
		    print $rh "Saving data to $fileName$CRLF";
		}
	    }

	    if ( $clientTable->{$clientID}->{'sendmsgid'} == 2 ) {
		print $rh "$msgID:complete$CRLF";
	    } elsif ( $clientTable->{$clientID}->{'sendmsgid'} == 1 ) {
		print $rh "complete$CRLF";
	    }

	#                                                      #
	#------------------------------------------------------#
	#             Options that affect all clients          #
	} elsif ( $cmd =~ /^LO/ ) {
	    if ( !$locked ) {
		{
		    lock($clients_lock);
		    $clientTable->{$clientID}->{'haslock'} = 1;
		    $locked = 1;
		}
		$outputQueue->enqueue( "$msgID:enqueued");
		$outputQueue->enqueue( "$msgID: Got DAQ lock");
		$outputQueue->enqueue( "$msgID:complete" );
		
	    } else {
		$outputQueue->enqueue( "$msgID:enqueued" );
		$outputQueue->enqueue( "$msgID: DAQ already locked" );
		$outputQueue->enqueue( "$msgID:complete" );
	    }

	} elsif ( $cmd =~ /^UL|UNLOCK/ ) {
	    if ( $clientTable->{$clientID}->{'haslock'} ) {
		{
		    lock($clients_lock);
		    $locked = 0;
		    $clientTable->{$clientID}->{'haslock'} = 0;
		}
		$outputQueue->enqueue( "$msgID:enqueued" );
		$outputQueue->enqueue( "$msgID: DAQ unlocked" );
		$outputQueue->enqueue( "$msgID:complete" );
	    }

	} elsif ( $cmd =~ /^SF/ ) {
	    if ( $cmd =~ /^SF (\d+)/ ) {
		if ( defined($1) ) {
		    $stat_freq = $1;
		}
		if ( $stat_freq < 10 ) {
		    $stat_freq = 10;
		} elsif ( $stat_freq > 600 ) {
		    $stat_freq = 600;
		}
	    }

	    $outputQueue->enqueue( "$msgID:enqueued" );
	    $outputQueue->enqueue( "$msgID:SF=$stat_freq" );
	    $outputQueue->enqueue( "$msgID:complete" );

	#------------------------------------------------------#
	#  Special command -- help needs to go to daq & motor  #
	} elsif ( $cmd =~ /^HR$/ ) {
	    $outputQueue->enqueue( "$msgID:enqueued" );

	    $inputQueue[$card]->enqueue( "25:$msgID:HR" );
	    if ( $motorQueue ) {
		usleep(100000);
		$motorQueue->enqueue( "$msgID:HR" );
	    }

	    if ( $verbose ) {
		print "$msgID enqueued...";
	    }

	#------------------------------------------------------#
	#        Is this a command for the CRiL motor?         #
	} elsif ( $cmd =~ /^M/ ) {
	    if ( !$cril ) {
		$outputQueue->enqueue( "$msgID:enqueued" );
		$outputQueue->enqueue( "$msgID: cmd??" );
		$outputQueue->enqueue( "$msgID:complete" );
	    } else {
		$motorQueue->enqueue("$msgID:$cmd");
	    }

	#------------------------------------------------------#
	#         Must be a command headed for the DAQ         #
	} else {

	    # Make sure it's at least potentially valid
	    # before the command is sent to the card
	    if ( !checkCmd($cmd) ) {

		if ( $verbose ) {
		    print "Bad command: $cmd. Bailing\n";
		}

		# Oh-oh... not a good command.. don't even bother
		# just put the standard card error message onto 
		# the response queue and bail
		$outputQueue->enqueue("$msgID:enqueued");
		$outputQueue->enqueue("$msgID:Cmd ??");
		$outputQueue->enqueue("$msgID:complete");

		lock($clients_lock);
		$clientTable->{$clientID}->{'state'} = "open";

		next;
	    }

	    # Assign the priority for this command
	    # Currently mostly the same -- so we're
	    # (almost) a fifo.
	    $priority = cmdPriority($cmd);

	    # OK... it's at least potentially good.. continue on
	    my $request = sprintf("%02i:%s:%s", 
				  $priority, $msgID, $cmd);

	    if ( defined($frwd) ) {

		if ( $frwd !~ /a|all/i ) {
		    ### Almost ready.... need to attach a msgID to the request
		    $frwdQueue{$frwd}->enqueue($request);
		} else {
		    while ( my ($id,$queue) = each(%frwdQueue) ) {
			$queue->enqueue($request);
			if ( $verbose ) {
			    print "Forwarding $request to $id\n";
			}
		    }
		}

	    } else {
		if ( $card !~ /A|ALL/i ) {

		    # Place it into the processing queue
		    $inputQueue[$card]->enqueue($request);

		    # And sort the queue by priority 
		    $inputQueue[$card]->sort();

		    # Let the client know it's in the queue
		    $outputQueue->enqueue("$msgID:enqueued");

		} else {
		    for ( my $i=0; $i<=$#inputQueue; $i++ ) {
			# Place it into the processing queue
			$inputQueue[$i]->enqueue($request);

			# And sort the queue by priority 
			$inputQueue[$i]->sort();

			# Let the client know it's in the queue
			$outputQueue->enqueue("$msgID:$i | enqueued");

		    }
		} # End else {
	    }

	} # End else

	$rh->close();
	$rh = undef;

	# Decrement the activity counter
	{
	    lock($ThreadPool::active);
	    $ThreadPool::active--;
	}

	# And mark this client as done reading
	{
	    lock($clients_lock);
	    $clientTable->{$clientID}->{"state"} = "open";
	}

    } # End while ( my $sd = $pool->dequeue() )

    if ( $verbose ) {
	print "Client thread " . threads->tid() . " done, closing up\n";
    }

    return threads->tid();
}

#--------------------------------------------------#
#  Worker thread to broadcast responses to clients #
#--------------------------------------------------#
sub sendResponse {

    while ($continue) {

	while ( $outputQueue->pending() ) {

	    my $response = $outputQueue->dequeue();

	    if ( !$response ) {
		last;
	    }

	    # loop all sockets
	    {
		lock $clients_lock;

		foreach my $key (keys(%$clientTable) ) {
		    my $value = $clientTable->{$key}->{'fileHandl'};
		    my $send  = $clientTable->{$key}->{'sendmsgid'};
		    my $bcast = $clientTable->{$key}->{'broadcast'};
		    my $rstat = $clientTable->{$key}->{'rcvstatus'};
		    my $haslo = $clientTable->{$key}->{'haslock'};
		    my ($msgID) = split(/:/, $response);

		    my $reply = $response;
		    $reply =~ s/$CRLF//;

		    # See if this client is taking broadcast messages
		    if ( !$bcast ) {
			if ( $msgID ne "stat" && $msgTable->{$msgID} ne $key ) {
			    next;
			}
		    }

		    if ( $msgID eq "stat" && !$rstat ) {
			next;
		    }

		    if ( !$send || $send == 0 ) {
			# Don't send the state messages
			if ( $response =~ /$msgID:enqueued|$msgID:complete/ ) {
			    next;
			}

			if ( $response =~ /$msgID:\d+ \| enqueued/ ) {
			    next;
			}

			if ( $response =~ /$msgID:\d+ \| complete/ ) {
			    next;
			}

			# Strip the message ID number if it's there
			$reply =~ s/$msgID://g;

		    } elsif ( $send == 1 ) {
			# Strip the ID number but forward the request state
			$reply =~ s/$msgID://g;

		    } else {    # $send must be equal to 2
			if ( defined($msgID) && $msgID !~ /stat/ ) {
			    if ( exists $msgTable->{$msgID} && 
				 $msgTable->{$msgID} ne $key ) {
				$reply =~ s/$msgID/xxxx/g;
			    }
			} else {
			    $reply =~ s/status\|//;
			}
		    }

		    # If there's a card number in here... Replace it
		    # with the serial number of the daq card
		    if ( $#inputQueue > 0 ) {
			if ( !$send || $send == 0 ) {
			    if ( $reply =~ /(\d) \| .*/ ) {
				if ( defined($1) ) {
				    my $card = $1;
				    $reply =~ s/$card/$SNReverseIndex[$card]/;
				}
			    }
			} else {
			    if ( $reply =~ /$msgID:(\d) \| .*/ ) {
				if ( defined($1) ) {
				    my $card = $1;
				    $reply =~ s/$card/$SNReverseIndex[$card]/;
				}
			    }
			}
		    }

		    # If someone locked the DAQ... send different
		    # responses to to the locker & the lokcee
		    if ( $reply =~ /Got DAQ lock/ ) {
			if ( !$haslo ) {
			    $reply = " DAQ has been locked";
			}
		    }

		    # Send responses to clients
		    if ( open(FH, ">&=", $value) ) {
			print FH "$reply$CRLF";
			close(FH);
		    } else {
			warn "$0: fdopen $value: $!";
		    }

		    # If this client is saving their data... send off
		    if ( defined($clientTable->{$key}->{outfile}) ) {
			$zipQueue->enqueue("$key|$reply");
		    }

		} # End foreach my $key

		# If this was the end of the response,
		# wipe this messge from the tables
		if ( $response =~ /complete$/ ) {
		    my ($id) = split(/:/, $response);
		    delete $msgTable->{$id};
		    delete $activeID{$id};
		}
	    }
	}
	usleep(25000);
    }

    return;
}

#---------------------------------------------------------------#
#   Zip utility thread for saving data files in the background  #
#---------------------------------------------------------------#
sub saveZipData {
    use IO::Compress::Zip qw(zip $ZipError);

    my %dataZip = ();

    $SIG{'TERM'} = $SIG{'STOP'} = $SIG{'INT'} =
	sub { $continue = 0; return; };

    if ( $verbose ) {
	print "Data writer starting up\n";
    }

    while ( $continue ) {
	my $item = $zipQueue->dequeue();
	if ( !$item ) {
	    $continue = 0;
	    next;
	}
	my ($clientID, $line) = split(/\|/, $item,2);

	# If the file does not exist.... create it now
	if ( !$dataZip{$clientID} || $line eq "create"  ) {

	    my $zipFile = $clientTable->{$clientID}->{'outfile'};
	    my $name = $zipFile;
	    $name =~ s/zip/txt/;

	    if ( $^O !~ /MSWin/ ) {
		($name) = reverse(split(/\//, $name));
	    } else {
		($name) = reverse(split(/\\/, $name));
	    }

	    $dataZip{$clientID} = 
		new IO::Compress::Zip ($zipFile, Append=>0, Name => $name,
				       ExtAttr => 0666 << 16)
		or warn "Zip failed: $ZipError\n";

	    $dataZip{$clientID}->autoflush();

	    if ( $verbose ) {
		print "Created $zipFile for data saving\n";
	    }

	    if ( $line eq "create" ) {
		next;
	    }
	}

	if ( $line eq "close" ) {
	    if ( $dataZip{$clientID} ) {
		$dataZip{$clientID}->flush();
		$dataZip{$clientID}->close();
		delete($dataZip{$clientID});
	    }
	    next;
	}

	$line =~ s/$CR|$LF|$CRLF//g;
	if ( $dataZip{$clientID} ) {
	    $dataZip{$clientID}->print($line . "$CRLF");
	    warn $ZipError if $ZipError;
	}
	print "Got $ZipError\n" if $ZipError && $verbose;

    } # End while ( $continue )

    if ( $verbose ) {
	print "Data saver done... closing up remaining files\n";
    }

    while ( my ($id, $z) = each(%dataZip) ) {
	$z->flush();
	$z->close();
    }

    return 0;
}
#---------------------------------------------------------------#

sub serverShutDown {
    my ($self) = @_;

    if ( $verbose ) {
	print "Done. cleaning up\n";
    }

    # Signal to all threads to wrap it up
    $continue = 0;

    # Tell the queue threads we're all done
    for ( my $i=0; $i<=$#inputQueue; $i++ ) {
	$inputQueue[$i]->enqueue(undef);
	$procThread[$i]->detach();
    }

    $outputQueue->enqueue(undef);
    $sendThread->detach();

    # Shut down the data saver
    $zipQueue->enqueue(undef);
    $dataThread->join();

    # Close down the client pool
    $threadPool->close();

    # Close the motor controller
    if ( $motorThread ) {
	$motorQueue->enqueue(undef);
	$motorThread->join();
    }

    # Join any other completed threads
    my @processes = threads->list( my $threads_joinable=0 );
    foreach my $proc (@processes) {
	$proc->join();
    }

    # Close up the TCP socket
    if ( $self->{_socket} ) {
	$self->{_socket}->close();
    }
    if ( $verbose ) {
	print "\n";
    }

    return;
}

#--------------------------------------------------#
#   Control interface for the CRiL stepper motor   #
#--------------------------------------------------#
sub motorControl {
    my ( $device ) = @_;
    if ( ! -c $device ) {
	warn "No motor $device\n";
	return -1;
    }

    # Include the CRiL Motor library ONLY if we actually need it
    require QN::motor;

    if ( $verbose ) {
	print threads->tid() . " starting up as motor control on $device\n";
    }

    my $motor = motor->new($device, $verbose);
    if ( !$motor ) {
	warn "Unable to connect to motor: $!\n";
	return -1;
    }

    # Set the current status of the motor
    $motor_current_status = "at " . 
	$motor->get_motor_int_degrees() . " degrees";

    # OK... we seem to have a good connection to the motor
    # Now sit quietly and wait for input from the queue
    while ( $continue ) {
	my $item = $motorQueue->dequeue();
	if ( !$item ) {
	    last;
	}

	my ($msgID, $mtrCmd) = split(/:/, $item);

	if ( $mtrCmd =~ /HR/i ) {
	    $outputQueue->enqueue($motor->help($msgID));
	    $outputQueue->enqueue("$msgID:complete");
	    if ( $verbose ) {
		print "Done.\n";
	    }
	    next;
	}

	# Acknowlege receipt
	$outputQueue->enqueue("$msgID:enqueued");

	my $response;

	if ( $mtrCmd =~ /^MP$/ ) {
	    $response = $motor->get_motor_int_degrees();
	    $motor_current_status = "at $response degrees";

	} elsif ( $mtrCmd =~ /^MI$/ ) {
	    $motor_current_status = "motor initializing";
	    $response = $motor->init_motor();
	    $motor_current_status = "at " .
		$motor->get_motor_int_degrees() . " degrees";

	} elsif ( $mtrCmd =~ /^MR$/ ) {
	    $motor_current_status = "motor reset";
	    $response = $motor->reset_motor();
	    $motor_current_status = "at " .
		$motor->get_motor_int_degrees() . " degrees";

	} elsif ( $mtrCmd =~ /^MV (\d+)/ || $mtrCmd =~ /^MV ([\+|\-]\d+)/ ) {
	    if ( defined($1) ) {
		my $degrees = int($1);
		if ( $degrees < -180 || $degrees > 180 ) {
		    $response = "Invalid move: Syntax MV [-180,180]";
		}

		$motor_current_status = "moving $degrees degrees";
		my $move = $motor->move_motor_relative($degrees);
		if ( $move == $degrees ) {
		    $response = "MV OK";
		} else {
		    $response = "MV Fail";
		}

		$motor_current_status = "at " . 
		    $motor->get_motor_int_degrees() . " degrees";

	    } else {
		$response = " Syntax??";
	    }

	} elsif ( $mtrCmd =~ /MA (\d+)/ ) {
	    if ( defined($1) ) {
		my $degrees = $1;
		if ( $degrees < 0 || $degrees > 360 ) {
		    $response = "Invalid move:  Syntax MA [0,360]";
		} else {
		    $motor_current_status = "moving to $degrees degrees";
		    my $move = $motor->move_motor_absolute($degrees);

		    if ( $move == $degrees ) {
			$response = "MV OK";
		    } else {
			$response = "MV Fail";
		    }
		    $motor_current_status = "at $move degrees";
		}
	    } else {
		$response = "Invalid move:  Syntax MA [0,360]";
	    }

	} else {
	    $response = " Cmd??";
	}

	$outputQueue->enqueue("$msgID:$response");
	$outputQueue->enqueue("$msgID:complete");

	usleep(25000);
    }

    if ( $verbose ) {
	print "Shutting down motor controller\n";
    }

    $motor->shutdown();

    $motor_current_status = "motor shutdown";

    return 0;
}

sub procQueue {   # Process the input queue
                  # Take commands off the queue and push them into 
                  # the pipeline to the card server. Then await
                  # a response on the pipe (ChildSocket)
    my ( $card ) = @_;

    if ( $verbose ) {
	print threads->tid() . " starting up... watching " . 
	    $daqcard[$card] . "\n";
    }

    my ( $msgID, $command );         # These need to persist
                                     # accross the while loop
    my $daq = QN::daq->new($daqcard[$card], $simulate, my $init = 0, $verbose);

    # Enable the DAQ streamer so we don't block waiting for a response
    local *cardSock = $daq->setupStream();
    *cardSock->autoflush(1);

    # Get the persistant status line for tagging when settings are changed
    $settings_status[$card] = $daq->get_persistent_status();

    # If we have more than one card on the line... 
    # Grab the serial number of this one and keep it 
    # for indexing the output
    if ( $#inputQueue > 0 ) {
	my $sn = $daq->get_serial_number();
	$SNIndex{$sn} = $card;
	$SNReverseIndex[$card] = $sn;
    }

    # Control variables for sleeping in the loop & getting status lines
    my $sleepy_time = 25000;
    my $now = 0;
    my $then = time();   # Number of seconds since the epoch
    my $isStat = 0;
    my $old_send_status = $send_status;

    while ( $continue ) {

	( $msgID, $command ) = checkQueue($card);  # Do we have something?
	if ( $msgID && $command ) {                # we do... deal with it

	    if ( $command =~ /END/ ) {
		$continue = 0;
		last;
	    }

	    if ( $command eq "HR" ) {
		if ( $verbose ) {
		    print "request $msgID enqueued on card=" . 
			$daq->device() . "...";
		}

		$outputQueue->enqueue($daq->help($msgID));
		if ( !$cril ) {
		    $outputQueue->enqueue("$msgID:complete");
		    if ( $verbose ) {
			print "Done.\n";
		    }
		}

		next;
	    }

	    # Put the command onto the card queue 
	    $daq->submit($msgID,$command);

	    # And scan for a reply
	    while ( my $reply = <cardSock> ) {

		if ( $reply && $reply !~ /NONE/ ) {
		    $isStat = 0;

		    if ( $send_status && $reply =~ /^stat:/ ) {

			$isStat = 1;

			if ( $reply =~ /EOT/ ) {
			    $outputQueue->enqueue("stat:complete");
			    last;
			}

			my $stat = $daq->make_status_line($reply);
			if ( !$stat ) {
			    next;
			}
			chomp($stat) if $stat;

			$stat .= ",LK=$locked";
			if ( $cril ) {
			    $stat .= ",MT=$motor_current_status";
			}

			$outputQueue->enqueue("stat:$stat");
			usleep(25000);
			next;

		    } # End if ( $reply =~ /stat:/ )

		    # Check and see if we've changed our settings
		    if ( my $update = $daq->settings_changed($reply) ) {
			$settings_status[$card] = 
			    $daq->get_persistent_status();
			    $outputQueue->enqueue("stat:$update");
		    }

		    if ( $#daqcard > 0 ) {
			$reply =~ s/:/:$card \| /;
		    }

		    if ( $reply =~ /EOT/ ) {
			$reply =~ s/EOT/complete/;
			$outputQueue->enqueue("$reply");
			last;
		    }

		    chomp($reply);
		    $outputQueue->enqueue($reply);

		} # End if ( $reply )

		# Check the current queue... if there's a command
		# waiting, deal with it here so that we aren't
		# waiting for the current command to complete before
		# the next one is sent (which would be a disaster
		# for a CE command)
		my ($id, $cmd) = checkQueue($card);
		if ( $id && $cmd ) {
		    if ( $cmd =~ /END/ ) {
			$continue = 0;
			last;
		    }
		    $daq->submit($id,$cmd);
		}

		if ( $old_send_status != $send_status ) {
		    if ( $old_send_status == 0 && $send_status > 0 ) {
			$daq->start_status();
			$old_send_status = $send_status

		    } elsif ( $send_status == 0 && $old_send_status > 0 ) {
			$daq->stop_status();
			$old_send_status = $send_status
		    }
		}

		# See if it's time for a status update
		$now = time();
		if ( $now > $then + $stat_freq && $send_status ) {
		    $daq->get_stat($inputQueue[$card]);
		    $then = $now;
		}

	    } # End while ( my $reply = <cardSock> )

	    if ( $verbose && !$isStat ) {
		print "Done\n\n";
		$isStat = 0;
	    }

	    # If we've receive the exit signal, bail out of the loop
	    if ( !$continue ) {
		last;
	    }

	} # End if ( $msgID && $command )

	# Grab anything that happens to be on the DAQ
	# (especially status lines)
	my $extraneous = $daq->check();

	if ( defined($extraneous) ) {
	    $outputQueue->enqueue("xxxx:$extraneous");
	}

	$now = time();
	if ( $now > $then + $stat_freq && $send_status ) {
	    $daq->get_stat($inputQueue[$card]);
	    $then = $now;
	}

	# Give up our place in the registers in case someone else needs it
	threads->yield();
	usleep($sleepy_time);

	if ( $old_send_status != $send_status ) {
	    if ( $old_send_status == 0 && $send_status > 0 ) {
		$daq->start_status();
		$old_send_status = $send_status

	    } elsif ( $send_status == 0 && $old_send_status > 0 ) {
		$daq->stop_status();
		$old_send_status = $send_status

	    }
	}

    } # End while ($continue);

    if ( $verbose ) {
	print "Queue completed. Exiting and shutting down DAQ\n";
    }

    # Close up the DAQ
    $daq->shutdown();

    return 0;
}

# Simple subroutine to check the input queue
# Done here in a sub rather than inside the 
# loop above (procQueue) because we have to 
# check in several different places to allow
# for multiplexing RX & TX on the line and 
# this way the queue check is always the same
sub checkQueue {
    my ( $card ) = @_;
    my ( $priority, $msgID, $command ) = (undef,undef,undef);

    $|=1;

    if ( $inputQueue[$card]->pending() ) {
	my $item = $inputQueue[$card]->dequeue();
	if ( !$item || $item =~ /END/ ) {
	    return "xxxx","END"
	}

	if ( $verbose && $item !~ /stat:/i ) {
	    print "processing $item...";
	}

	( $priority, $msgID, $command ) = split(/:/, $item);

	if ( !defined($msgID) ) {
	    warn "Unable to associate to request! Bailing\n";
	    return undef, undef;
	}

    } # End if ( $inputQueue[$card]->pending() )

    return $msgID, $command;
}

sub forward {
    my ( $queue, $alias, $host, $port ) = @_;
    my %lookup = ();
    my $client = new Client($host, $port);

    if ( !$client ) {
	if ( $verbose ) {
	    print "Unable to connect to remote server $alias\n";
	}
	return 0;
    }

    # Set the remote server to send back message IDs
    $client->send("SI 2$CRLF");

    # Do a quick read to grab the welcome message & discard it
    while ( my $result = $client->read() ) {}

    if ( $verbose ) {
	print "Connected to new slave server $alias @ $host:$port\n";
    }

    while ( my $item = $queue->dequeue() ) {
	if ( !$item ) {
	    last;
	}

	# OK... we've got a command... Prepare it for the slave server
	my ( $priority,$id,$cmd ) = split(/:/, $item);
	$client->send($cmd.$CRLF);

	while ( my $result = $client->read() ) {

	    # Strip newlines, carrige returns, etc
	    $result =~ s/$CR|$LF|$CRLF//g;

	    if ( $result =~ /Welcome/ ) {             # Just in case
		next;

	    } elsif ( lc($result) =~ /enqueued/ ) {  # Remote got the command
		my ($rid) = split(/:/, $result);
		$lookup{$rid} = $id;

		$result =~ s/$rid:/$rid:$alias \| /;
		$result =~ s/$rid/$id/;

		if ( $verbose ) {
		    print "request $id enqueued on $alias\n";
		}
		next;

	    } elsif ( lc($result) =~ /complete$/ ) {
		my ($rid) = split(/:/, $result);
		delete( $lookup{$rid} );
		next;
	    }

	    # Get the ID Tag from the remotes response
	    my ($rid) = split(/:/, $result);

	    # Prepend the host alias to the response
	    $result =~ s/$rid:/$rid:$alias \| /;

	    # Strip off the remote servers msgID & replace it with our own
	    $result =~ s/$rid/$lookup{$rid}/;

	    # And forward the response to our own output queue
	    $outputQueue->enqueue($result);

	}
    }

    $client->close();

   return 0;
}

# Generate a unique, random 4 character ID for each request
sub requestID {
    my ( $length ) = @_;
    my $msgID  ="";
    $length = ( defined $length ) ? $length : $idlength;

    for(my $i=0 ; $i<$length ;) {
	my $j = chr(int(rand(127)));
	if($j =~ /[a-z0-9]/ && (!length($msgID) || $j !~ /$msgID/) ) {
	    $msgID .= $j;
	    $i++;
	}
    }

    # Re-entrent call in case of dupliate IDs. Carefull.... Carefull...
    if ( defined($activeID{$msgID}) ) {
	if ( $verbose ) {
	    warn ">>>>>>>>>>>>>>>>> Duplicate ID! <<<<<<<<<<<<<<<<\n";
	}
	$msgID = &requestId;
    }

    $activeID{$msgID} = 1;
    return $msgID;
}

# Perl trim function to remove whitespace 
# from the start and end of the string as
# well as \n, \r (or \O12 \O15 if you like)
sub trim {
    my ($string) = @_;

    chomp($string);
    if ( ord(substr($string, length($string)-1)) == 13 ) {
	chop($string);
    }

    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

return 1;
