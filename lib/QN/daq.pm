package QN::daq;

use strict;
use warnings;

use QN::cardsim;

my $OS = $^O;

if ( $OS ne "MSWin32" ) {
    require Device::SerialPort;
} else {
    require Win32::SerialPort;
}
######################################################################
# A module's version number is stored in $ModuleName::VERSION; certain 
# forms of the "use" built-in depend on this variable being defined.

our $VERSION = '1.00';

# Inherit from the "Exporter" module which handles exporting functions.
# Most procedural modules make use of this.
 
use base 'Exporter';
 
# When the module is invoked, export, by default, the function "hello" into 
# the namespace of the using code.
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(checkCmd cmdPriority cmdIsQuery);

##########################################################################


use IO::Select;
use Socket;
use Time::HiRes qw(usleep);

use threads;
use threads::shared;
use QN::ThreadQueue;

my $CRLF = "\015\012";
my $CR   = "\015";
my $LF   = "\012";

sub new {

    my ($class, $PORT, $simulate, $initCard, $verbose ) = @_;
    my $BAUD = 115200;
    my $daq  = 0;
    my $test = 0;
    my $DEV;

    if ( !$PORT ) {
	$simulate = 1;
    }

    if ( !$simulate ) {
	$simulate = 0;
    }

    # Create a new serial instance to talk to the DAQ
    if ( !$simulate ) {

	$daq = ($OS ne "MSWin32" ) ?
	    Device::SerialPort->new( $PORT ) : 
	    Win32::SerialPort->new( $PORT );
	    warn "Can't Open $PORT: $!\n" if !$daq;

    } else {
	$daq = new cardsim();
    }

    if ( !$daq || $simulate ) {
	$initCard = 1;
	$test = 1;
	$daq = new cardsim();

	if ( $verbose ) {
	    print "Running in test mode\n";
	}
    }

    if ( !$test ) {
	# Set the board parameters
	$daq->baudrate($BAUD)   || die "failed to set baud rate $!\n";
	$daq->parity("none")    || die "failed setting parity: $!";
	$daq->databits(8)       || die "failed setting databits: $!";
	$daq->stopbits(1)       || die "failed to set stopbits:$!";
	$daq->handshake("none") || die "failed setting handshake";

	$daq->read_const_time(200);
	$daq->read_char_time(0);

	# And write them onto the line
	$daq->write_settings()  || die "no settings";
    }

    my $counter = 0;
    my $self = {
	_test     => $test,
	_counter  => $counter,
	_daq      => $daq,
	_port     => $PORT,
	_verbose  => $verbose,
	_queue    => new ThreadQueue(),
	_streamer => undef,
	_SIM      => undef,
	_STOP     => 0,
	_SN       => undef,
	_pStatus  => undef
    };

    bless $self, $class;

    if ( $initCard ) {
	$self->init();
    }

    
    my $serial = $self->send("SN");
    $serial =~ /.*Serial#=(\d{4})/;
    if ( defined($1) ) {
	$self->{_SN} = $1;
    } else {
	warn "Unable to figure out which card we've got!\n";
    }

    return $self;
}

sub init {
    my ($self) = @_;

    if ( $self->{_test} ) {
	return;
    }

    # Make sure we're not going to get inundated with previous data
    $self->{_daq}->write("CD\r");
    $self->{_daq}->write("RB\r");

    return;
}

#-------------------------------------------#
# Cleanup and exit semi-gracefully          #
#-------------------------------------------#
sub shutdown {
    my ($self) = @_;
    my $test = $self->{_test};
    my $cardQ = $self->{_queue};

    if ( $self->{_streamer} ) {
	$cardQ->enqueue(undef);
	$self->{_streamer}->detach();
	$cardQ->cleanup();
    }

    if ( !$test ) {
	# Make sure we're clean...
	$self->send("CD");
	$self->send("ST 0");
    }

    # Shut down gracefully
    $self->{_daq}->close();

    # And undef the memory
    undef $self;

    return undef;
}

sub device {
    my ( $self ) = @_;
    return $self->{_port} if $self->{_port} || undef;
}

#-------------------------------------------#
# Init the streamer: Set up a socket pair   #
# for communication and send the streamer   #
# into the background as a thread (could as #
# well fork the streamer)                   #
#-------------------------------------------#
sub setupStream {
    my ($self) = @_;
    my ( $cardSocket, $serverSocket );

    socketpair( $cardSocket, $serverSocket,
	    PF_UNIX, SOCK_STREAM, PF_UNSPEC) || die "socket: $!";
    select( (select($cardSocket),   $|=1)[0] );
    select( (select($serverSocket), $|=1)[0] );

    $self->{_socket} = $cardSocket;

    $self->{_streamer} = threads->new( 'stream', $self )->detach();
    return $serverSocket;
}

#-------------------------------------------#
# Queue up a command for the card streamer  #
#-------------------------------------------#
sub submit {
    my ($self,$msgID,$command) = @_;
    my $sock = $self->{_socket};
    my $cardQ = $self->{_queue};

    $|=1;

    # If it's not a good command... don't 
    # waste any time. Just throw an error and bail
    if ( !&checkCmd($command) ) {
	print $sock "$msgID: Cmd??\nEOT\n";
	return -1;
    }

    # Put the command in the queue for processing
    $cardQ->enqueue($msgID.":".$command);

    if ( $self->{_verbose} ) {
	print "request $msgID enqueued on card=$self->{_port}...";
    }

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

    my $daq = $self->{_daq};
    my $continue = 1;
    my $cardQ = $self->{_queue};

    $SIG{'STOP'} = sub {
	$continue = 0;
	last;
    };

    my $sock = $self->{_socket};

    my $sleepy_time = 10000;

    while ($continue) {
	my ($msgID,$command) = split(/:/,$cardQ->dequeue());
	my %cmdLookup = ();

	if ( !$command || $command eq "END" ) {
	    $continue = 0;
	    last;
	}
	$command = uc($command);

	my $writeOK = $self->put($command);
	if ( !$writeOK ) {
	    next;
	}

	# Set up a streaming read from the card
	$daq->read_const_time(200);    # 1/5s timeout between reads
	$daq->read_char_time(0);       # Read each character

	# How many seconds to wait for the next line in a response
	my $STALL_DEFAULT = ($command ne "CE") ? 5 : 1200;
	my $timeout = $STALL_DEFAULT;

	my $chars = 0;
	my $buffer = "";

	my $newCmdResp = 0;
	my $cmdKey = "";

	while ( $timeout > 0 ) {
	    my ( $count,$saw ) = $daq->read(255); # will read up to 255 chars
	    
	    if ( $count > 0 ) {
		$chars += $count;
		$buffer .= $saw;

		if ( $buffer ) {

		    # Strip off carrige returns
		    $buffer =~ s/\r//g;

		    # See if we got a complete line at the end
		    my $keeplast = 0;
		    if ( ord(substr($buffer,length($buffer)-1)) != 10 ) {
			$keeplast = 1;
		    }

		    if ( scalar(keys(%cmdLookup)) ) {

			# Look at the buffer... if it contains the 
			# command then the following output is from
			# newCmd
			foreach my $key (keys(%cmdLookup)) {
			    if ( $buffer =~ /$key/ ) {
				# Start of response to $newCmd
				$newCmdResp = 1;
				$cmdKey = $key;
			    } elsif ( $buffer =~ /^\w{8} \w{2}/ ) {
				# Back to the CE command
				$newCmdResp = 0;
				delete $cmdLookup{$key};
				$cmdKey = "";
			    }
			}
		    }

		    # break the buffer into lines of output
		    my @output = split(/\n/, $buffer);

		    if ( $keeplast == 1 ) {
			$buffer = pop(@output);
		    } else {
			$buffer = "";
		    }
		    my $sendID = ( $newCmdResp == 0 ) ? $msgID : 
			$cmdLookup{$cmdKey};

		    # Send each line back to the server
		    for my $line (@output) {
			if ( $line =~ /^[A-Z][A-Z]$/ ) {
			    next;
			}

			# If this was the result of an HE command... append our
			# special server codes to the list
			if ( $command eq "HE" and $line =~ /HE\,H1=Page1/ ) {
			    $line =~ s/HT=Trigger/HT=Trigger, HR=Server/;
			} # End if ( $command eq "HE" ...

			print $sock "$sendID:$line$CRLF";

		    } # End for ( my $line (@output) )

		} # End if ( $buffer )

		# reset the timer 
		$timeout = $STALL_DEFAULT;

	    } else {                                # End if ( $count > 0 )
		if ( $buffer ne "" ) {
		    print $sock "$msgID:$buffer$CRLF";
		} else {
		    print $sock "NONE$CRLF";        # If there's nothing in the
		}                                   # buffer, force the server to
		$buffer = "";                       # cycle & check it's queue
		$timeout--;
	    }
	    
	    # Check for any new commands on the queue
	    if ( $cardQ->pending() ) {
		my ($id,$newCmd) = split(/:/,$cardQ->dequeue());

		if ( $newCmd eq "CD" ) {
		    $STALL_DEFAULT = 5;
		}
		$timeout = $STALL_DEFAULT;

		# If we're currently running a command... we'll need
		# a way to keep track of the output for the new one
		$cmdLookup{$newCmd} = $id;
		$self->put($newCmd);
		next;

	    } # End if ( $cardQ->pending() )

	} # End while ( $timeout > 0 )

	# All done... signal our caller that the stream is closed
	print $sock "$msgID:EOT$CRLF";

	$command = undef;

	# Take a nap
	usleep(10000);

    } # End while ($continue)

    print $sock "EOT$CRLF";

    return 0;
}


#-------------------------------------------#
#    Generate and automagical status line   #
#-------------------------------------------#
sub status {
    my ( $self ) = @_;

    my $persistent_status = "status|SN=" . $self->{_SN};
    my $line;

    # Get the threshold levels
    $self->put("TL");
    $line = $self->get();
    $line =~ s/$CR//g;

    $line =~ /^TL\nTL (L0=.*)/;
    if ( defined($1) ) {
	$persistent_status .= ',' . $1;
	$persistent_status =~ s/\s/,/g;
    } else {
	warn "TL RegExp failed: $line\n";
    }

    # The coincidence settings
    $self->put("DC");
    $line = $self->get();
    $line =~ s/$CR//g;

    $line =~ /^DC\nDC (C0=\w{2})/;
    if ( defined($1) ) {
	$persistent_status .= ',' . $1;
    } else {
	warn "DC RegExp failed: $line\n";
    }

    # And the location of the card
    $self->put("DG");
    $line = $self->get();
    
    $line =~ /Latitude:  (.*)/;
    if ( defined($1) ) {
	my $temp = $1;
	$temp =~ s/$CR//g;
	$temp =~ s/\s//g;

	$persistent_status .= ",LT=" . $temp;

    } else {
	warn "Failed to get latitude: $line\n";
    }

    $line =~ /Longitude: (.*)/;
    if ( defined($1) ) {
	my $temp = $1;
	$temp =~ s/$CR//g;
	$temp =~ s/\s//g;

	$persistent_status .= ",LG=" . $temp;
    } else {
	warn "Failed to get longitude: $line\n";
    }

    $line =~ /Altitude:  (.*)/;
    if ( defined($1) ) {
	my $temp = $1;
	$temp =~ s/$CR//g;
	$temp =~ s/\s//g;

	$persistent_status .= ",AL=" . $temp;
    } else {
	warn "Failed to get altitude: $line\n";
    }

    $self->{_pStatus} = $persistent_status;

    return $persistent_status;
}

sub get_serial_number {
    my ( $self ) = @_;
    return $self->{_SN};
}

sub get_stat {
    my ( $self, $queue ) = @_;
    $queue->enqueue("10:stat:ST");
    return;
}

sub get_persistent_status {
    my ($self) = @_;

    if ( !$self->{_pStatus} ) {
	$self->status();
    }
    return $self->{_pStatus};
}

sub settings_changed {
    my ( $self, $response ) = @_;
    my $pstatus = $self->{_pStatus};

    if ( $response =~ /TL \d+/ ) {
	$response =~ /TL (\d+) (\d+)/;
	my $channel = $1;
	my $thresh  = $2;

	if ($pstatus !~ /L$channel=$thresh/ ) {
	    $pstatus =~ s/L$channel=\w{1,4}/L$channel=$thresh/;
	    $self->{_pStatus} = $pstatus;
	    return "status|UP=1,L$channel=$thresh";
	}
    } elsif ( $response =~ /WC/ ) {
	my ( $dummy, $ci ) = split(/=/, $response);
	if ( $ci ) {
	    $ci =~ s/$CR|$LF//g;
	    if ( $pstatus !~ /C0=$ci/ ) {
		$pstatus =~ s/C0=\w{2}/C0=$ci/;
		$self->{_pStatus} = $pstatus;
		return "status|UP=1,C0=$ci";
	    }
	}
    }

    return undef;
}

sub make_status_line {
    my ( $self, $status ) = @_;
    $status =~ s/$LF|$CR|$CRLF//g;
    $status =~ s/stat://;

    if ( $status =~ /^ST$/ ) {
	return undef;
    }

    my $hasST = 0;
    my $hasDS = 0;

    if ( $status =~ /ST/ ) {
	$hasST = 1;
    }
    if ( $status =~ /DS/ ) {
	$status =~ s/DS //;
	$hasDS = 1;
    }

    if ( $status =~ /EOT/ ) {
	return undef;
    }

    my $stat;

    if ( $hasST && $hasDS ) {

	my @temp = split(/ /, $status);
	my $time = $temp[5];             # ST Line
	my $date = $temp[6];
	my $vald = $temp[7];
	my $sats = $temp[8];
	my $ser  = $temp[11];

	$stat = "SN=$ser,DT=$date,TI=$time,VL=$vald,SA=$sats";

	if ( $#temp > 13 ) {             # DS if it's there
	    my @scalars = splice(@temp, eval($#temp-4), $#temp);

	    $stat .= ",S0=" . hex($scalars[0]) . ",S1=" . hex($scalars[1]) . 
		",S2=" . hex($scalars[2]) . ",S3=" . hex($scalars[3]) . 
		",TG=" . hex($scalars[4]);
	}

    } elsif ( $hasST ) {

	my @temp = split(/ /, $status);
	my $time = $temp[5];             # ST Line
	my $date = $temp[6];
	my $vald = $temp[7];
	my $sats = $temp[8];
	my $ser  = $temp[11];

	$stat = "SN=$ser,DT=$date,TI=$time,VL=$vald,SA=$sats";

    } elsif ( $hasDS ) {
	my @scalars = split(/ /, $status);

	$stat = "SN=" . $self->{_SN} . 
	    ",S0=" . hex($scalars[0]) . 
	    ",S1=" . hex($scalars[1]) . 
	    ",S2=" . hex($scalars[2]) . 
	    ",S3=" . hex($scalars[3]) . 
	    ",TG=" . hex($scalars[4]);

    } else {   # Not sure what this is
	return undef;
    }

    return "status|$stat" if $stat || undef;

}

#-------------------------------------------#
# Put a command onto the card and check to  #
# make sure we got it all.                  #
#-------------------------------------------#
sub put {
    my ($self, $command) = @_;
    my $daq  = $self->{_daq};

    # Make sure we'll have a reasonable command
    $command =~ s/\r//g;
    $command =~ s/\n//g;
    $command = uc($command);

    # If it's not a good command... don't 
    # waste any time. Just throw an error and bail
    if ( !&checkCmd($command) ) {
	return 0;
    }

    # Put it onto the line...
    my $sent = $daq->write("$command$CR");

    # And make sure it all went OK
    if ( $sent != length($command.$CR) ) {
	warn "Send error!\n";
    }

    return $sent;
}


#-------------------------------------------#
# Get a complete response from the card     #
#-------------------------------------------#
sub get {
    my ( $self ) = @_;
    my $daq = $self->{_daq};

    $daq->read_const_time(100);    # 0.1s timeout
    $daq->read_char_time(0);       # Don't read each character

    my $STALL_DEFAULT=2; # how many seconds to wait for new input
    my $timeout=$STALL_DEFAULT;

    my $chars = 0;
    my $buffer = "";
    while ( $timeout > 0 ) {
	my ( $count,$saw ) = $daq->read(255); # will read _up to_ 255 chars
	if ( $count > 0 ) {
	    $chars += $count;
	    $buffer .= $saw;
	} else {
	    $timeout--;
	}
    }

    if ( $timeout == 0 && !length($buffer) ) {
	$buffer = " Syntax??";
    }

    return $buffer;
}

sub check {
    my ( $self ) = @_;
    my $buffer = $self->get();
    if ( $buffer =~ /Syntax/ ) {
	return undef;
    } else {
	return $buffer;
    }
}

sub start_status {
    my ( $self ) = @_;
    $self->send("ST 2 30");
    return;
}

sub stop_status {
    my ( $self ) = @_;
    $self->send("ST 0");
    return;
}

#-------------------------------------------#
# Put a command on the card, then block and #
# wait for it to fully reply. Unsuited to a #
# streaming command like CE                 #
#-------------------------------------------#
sub send {
    my ($self, $command) = @_;

    my $sendOK = 0;
    my $response = undef;

    $sendOK = $self->put($command . $CR);
    if ( $sendOK ) {
	$response = $self->get();
    } else {
	warn "Send fail on DAQ\n";
	$response = " Err??";
    }

    return $response if ( $response ) || " Syntax??";
}

#----------------------------------------#
#  Add a page to the DAQ help screens    #
#----------------------------------------#
sub help {
    my ( $self,$msgID ) = @_;

    my $HR;

    $HR  = "$msgID:CL     - Close this connection to the server\n$CRLF";
    $HR .= "$msgID:BC n   - Receive data BroadCasts 0=false 1=true BC=read$CRLF";
    $HR .= "$msgID:SI n   - Send ID 0=None 1=ACK/COM 2=ID: SI=read$CRLF";
    $HR .= "$msgID:SV f   - Set file name (f) for output SV=read SV close=close file$CRLF";
    $HR .= "$msgID:LO     - Lock the DAQ -- prevent others from altering settings$CRLF";
    $HR .= "$msgID:UL     - Unlock the DAQ -- allow other users to alter settings$CRLF";
    $HR .= "$msgID:SS     - Send (expanded) Status lines. 0=false 1=true SS=read$CRLF";
    $HR .= "$msgID:SF t   - Set status Frequency t sec = [10,600] SF=read";

    return $HR if $HR || undef;
}

#----------------------------------------#
#    Class calls to static methods       #
#----------------------------------------#

sub validateCmd {
    my ( $self, $command, $quickCheck ) = @_;

    if ( !$command ) {
	return 0;
    }

    if ( !$quickCheck ) {
	$quickCheck = 0;
    }

    return &checkCmd($command, $quickCheck);
}

sub getCmdPri {
    my ( $self, $command ) = @_;
    if ( !$command ) {
	return -1;
    } else {
	return &cmdPriority($command);
    }
    return -1;
}

#----------------------------------------#
#    Static methods                      #
#----------------------------------------#

sub checkCmd {
    my ( $command, $quickCheck ) = @_;

    my %cmdRegExp = ( 
	'HE' => "^HE\$", 
	'TL' => "^TL\$|^TL [0-4] \\d{1,4}\$|^TL 0[0-4] \\d{1,4}\$",
	'CE' => "^CE\$",
	'CD' => "^CD\$",
	'DC' => "^DC\$",
	'WC' => "^WC [0-6] [0-3][0-9A-F]\$|^WC 0[0-6] [0-3][0-9A-F]\$",
	'DT' => "^DT\$",
	'WT' => "^WT [1,2] [0-9A-F]\$",
	'DG' => "^DG\$",
	'DS' => "^DS\$",
	'RE' => "^RE\$",
	'RB' => "^RB\$",
	'SB' => "^SB [1-7] \\w*\$",
	'SA' => "^SA [0-2]\$",
	'TH' => "^TH\$",
	'V1' => "^V1\$",
	'V2' => "^V2\$",
	'V3' => "^V3\$",
	'H1' => "^H1\$",
	'H2' => "^H2\$",
	'H3' => "^H3\$",
	'HB' => "^HB\$",
	'HS' => "^HS\$",
	'HT' => "^HT\$",
	'NA' => "^NA [0-2]\$", 
	'NM' => "^NM [0-2]\$",
	'TE' => "^TE [0-2]\$", 
	'TD' => "^TD [0-2]\$", 
	'TV' => "^TV\$|^TV [0-2]\$",
	'SN' => "^SN\$|^SN \\w*\\s\\d{1,5}\$",
	'BA' => "^BA\$|^BA \\d{1,4}\$",
	'FL' => "^FL \\w*\$",
	'FR' => "^FR\$",
	'FM' => "^FMR [[:xdigit:]]{1,3}\$",
	'ST' => "^ST\$|^ST [0-3]\$|^ST [1-3] \\d{1,2}\$",
	'TI' => "^TI\$|^TI 0\$",
	'U1' => "^U1\$|^U1 0\$",
	'VM' => "^VM 1\$",

	'HR' => "^HR\$"
	);

    $command = uc($command);
    my $index = substr( $command, 0, 2 );

    if ( $quickCheck ) {
	return defined($cmdRegExp{$index});
    } elsif ( defined($cmdRegExp{$index}) ) {
	return ($command =~ /$cmdRegExp{$index}/);
    } else {
	return 0;
    }
    return 0;
}

sub cmdIsQuery {
    my ( $command ) = @_;
    if ( !$command ) {
	return -1;
    } elsif ( length($command) > 2 ) {
	return 0;
    } else {
	$command = uc(substr($command, 0, 2));
    }

    my %cmdQuery = ('SN' => 1, 'SS' => 1, 'HE' => 1,
		    'H1' => 1, 'H2' => 1, 'HB' => 1,
		    'HS' => 1, 'HT' => 1, 'HR' => 1,
		    'DC' => 1, 'DT' => 1, 'DG' => 1,
		    'DS' => 1, 'TH' => 1, 'V1' => 1,
		    'V2' => 1, 'V3' => 1, 'ST' => 1,
		    'BA' => 1, 'CE' => 0, 'CD' => 0,
		    'WC' => 0, 'WT' => 0, 'RE' => 0,
		    'RB' => 0, 'SA' => 0, 'ST' => 1,
	            'TL' => 1, 'H3' => 1, 'FR' => 1,
		    'TI' => 1, 'TV' => 1 );

    if ( exists $cmdQuery{$command} ) {
	return $cmdQuery{$command};
    } else {
	return 0;
    }
    
    return 0;
}

sub cmdPriority {
    my ( $command ) = @_;
    if ( !$command ) {
	return -1;
    } else {
	$command = uc(substr($command, 0, 2));
    }

#-----------------------------------------------#
# $cmdPriority: Basically unused for now. So    #
# the server just acts as a fifo, but in place  #
# so we could give different commands different #
# priorities by default. If we want to. Later.  #
#-----------------------------------------------#
    my %cmdPri = ( 'HE' => 25,
		   'TL' => 25,
		   'CE' => 99,
		   'CD' => 1,
		   'DC' => 25,
		   'WC' => 25,
		   'DT' => 25,
		   'WT' => 25,
		   'DG' => 25,
		   'DS' => 25,
		   'RE' => 25,
		   'RB' => 25,
		   'SB' => 25,
		   'SA' => 25,
		   'TH' => 25,
		   'V1' => 25,
		   'V2' => 25,
		   'V3' => 25,
		   'H1' => 25,
		   'H2' => 25,
		   'H3' => 25,
		   'HB' => 25,
		   'HS' => 25,
		   'HT' => 25,
		   'NA' => 25,
		   'NM' => 25,
		   'TE' => 25,
		   'TD' => 25,
		   'TV' => 25,
		   'SN' => 25,
		   'BA' => 25,
		   'FL' => 25,
		   'FR' => 25,
		   'FM' => 25,
		   'ST' => 25,
		   'TI' => 25,
		   'U1' => 25,
		   'VM' => 25,
		   'HR' => 25
	);

    if ( $cmdPri{$command} ) {
	return $cmdPri{$command};
    } else {
	return 25;
    }
    return -1;
}

return 1;
