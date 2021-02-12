package motor;

use strict;
use warnings;
use Device::SerialPort;
use Time::HiRes qw(usleep);

my $degrees = 0;
my $position = 0;
my $query = 0;
my $motor;
my $steps_per_degree = 853.333333;
my $handle = 0;
my $absolute = -1;
my $init = 0;
my $reset;
my $verbose = 0;
my $help = 0;

my $home = $ENV{"HOME"};

my $CRLF = "\015\012";
my $CR   = "\015";
my $LF   = "\012";

sub new() {
    my ($class, $port, $vrbs) = @_;
    
    if ( $vrbs ) {
	$verbose = $vrbs;
    }

    my $self = {
	_test => 0,
	_PORT => $port,
	_BAUD => 9600,
	_filehandle => 0,
	_test => 0,
	_current_status => 'no motor',
    };

    bless $self, $class;

    $self->open_motor_port();
#    $self->reset_motor();
#    $self->init_motor();

#    if ( !$self->{_test} ) {
#	$self->lock_motor();
#    }

    return $self;
}

#================================ Start Subs ================================#
sub round() {
    my ($number) = @_;
    my $int = int($number);
    my $remainder = $number - $int;
    if ( $remainder < 0.5 ) {
	return $int;
    } else {
	return $int+1;
    }
    return -1;
}

sub open_motor_port() {
    my ($self) = @_;

    # Open the motor port
    $motor = Device::SerialPort->new ($self->{_PORT}) || 
	warn "Can't Open $self->{_PORT}: $!\nrunning in test mode\n";

    if ( $motor == 1 ) {
	$self->{_test} = 1;
    }

    if ( !($self->{_test}) ) {
	# Set the board parameters
	$motor->baudrate($self->{_BAUD}) || die "failed to set baud rate $!\n";
	$motor->parity("none")           || die "failed setting parity: $!";
	$motor->databits(8)              || die "failed setting databits: $!";
	$motor->stopbits(1)              || die "failed to set stopbits: $!";
	$motor->handshake("none")        || die "failed to set handshaking: $!";
	# If we don't get anything in 1 sec... bail
	$motor->read_const_time(1000);

	# And write them onto the line
	$motor->write_settings()  || die "no settings";
    
	open(my $filehandle, "+>$self->{_PORT}");
	if ( $filehandle <= 0 ) {
	    die "Unable to communicate with motor:$!\n";
	}
	$self->{_filehandle} = $filehandle;

	$self->{_current_status} = "initialized";
    }

    return;
}

sub shutdown() {
    my ($self) = @_;
    my $handle = $self->{_filehandle};

    $self->{_current_status} = "shutting down";

    if ( !$self->{_test} ) {
	$motor->close();
	close($handle);
    }
    undef $motor;

#    if ( !$self->{_test} ) {
#	$self->unlock_motor();
#    }
    return;
}

sub get_motor_steps() {
    my ($self) = @_;
    if ( $self->{_test} ) {
	return -1.0;
    }

    my $handle = $self->{_filehandle};
    if ( !$handle ) {
	warn "Unable to communicate with motor!\n";
    }

    # Get the current position of the motor
    $motor->write("/1?0\r");

    my $response = <$handle>;

    if ( $response ) {
	$response =~ m/\S*\/0\`(\d+)\S*/;
	my $position;
	if ( defined $1 ) {
	    $position = $1;
	} else {
	    $position = -1;
	}
	return $position;
    } else {
	return -1.0;
    }

}

sub get_motor_degrees() {
    my ($self) = @_;
    if ( $self->{_test} ) {
	return -1;
    }

    $position = $self->get_motor_steps();
    while ( $position < 0 ) {
	$position = $self->get_motor_steps();
    }
    $position /= $steps_per_degree;

    return $position;
}

sub get_motor_int_degrees() {
    my ($self) = @_;
    if ( $self->{_test} ) {
	return -1;
    }

    $position = $self->get_motor_steps();
    while ( $position < 0 ) {
	$position = $self->get_motor_steps();
    }

    $position /= $steps_per_degree;
    $position = &round($position);

    $self->set_status("at " . $position . " degrees");

    return $position;
}

sub move_motor(\$) {
    my ($self,$command) = @_;

    if ( $self->{_test} ) {
	return 0;
    }
    my $handle = $self->{_filehandle};

    ($verbose != 0 ) ? print "Sending $command\n" : 0;

    $motor->write("$command\r");
    my $response = <$handle>;

    # Check the response to make sure the command suceeded
    if ( $response ) {
	 # Strip off the unprintable characters
	$response = substr($response, 1, length($response)-4);
	if ( $response ne "/0@" ) {
	    warn "Motor responded with $response!\n";
	    return 1;
	}
    } else {
	warn "No response from motor\n";
	return 2;
    }
    return 0;
}

sub move_motor_relative() {
    my ($self,$degrees) = @_;

    if ( $self->{_test} ) {
	$degrees = $self->check_angle($degrees);
	print "Moving relative $degrees degrees\n";
	return 0;
    }

    $self->{_current_status} = "moving $degrees degrees";

    my $start = $self->get_motor_steps();
    while ( $start < 0 ) {
	$start = $self->get_motor_steps();
    }

    my $steps = abs($degrees) * $steps_per_degree;
    if ( &round($steps) < 1 ) {
	return 2;
    }

    my $newangle = $position + $degrees;

    my $command = "";
    my $newpos = -1;

    if ( $degrees > 0 ) {                                  # If we're moving clockwise... 
	if ( $start + $steps > 360*$steps_per_degree ) {   # We'll have to reset if we go through zero
	    $newpos = &round($start + $steps - 360*$steps_per_degree);
	    $command = sprintf("/1P%iz%iR", &round($steps),$newpos);
	} else {
	    $command = sprintf("/1P%iR", &round($steps));
	}
    } else {
	if ( $steps > $start ) {                           # If we're headed counter-clockwise
	                                                   # We have to set zero ahead, move, and reset
	    $newpos = &round(360*$steps_per_degree - $steps + $start);
	    $command = sprintf("/1z%iD%iz%iR", &round(360*$steps_per_degree), &round($steps),$newpos);
	} else {
	    $command = sprintf("/1D%iR", &round($steps));
	}
    }

    ($verbose != 0) ? print "Moving " . &round($steps) . 
	" from $start: $command\n" :0;

    my $badMove = $self->move_motor($command);
    if ( $badMove != 0 ) {
	warn "Unable to complete $degrees degree move\n";
	return $badMove;
    }
    
    $self->block($newangle);
    $position = $self->get_motor_int_degrees();

    return &round($degrees);
}

sub move_motor_absolute() {
    my ($self, $angle) = @_;

    if ( $self->{_test} ) {
	$angle = $self->check_angle($angle);
	print "Moving to $angle degrees\n";
	return 0;
    }

    $self->{_current_status} = "moving to $degrees";

    # Get the current position of the motor in degrees
    my $curpos = $self->get_motor_degrees();

    # Start by assuming a clockwise rotation....
    my $path = $angle - $curpos;

    # If |path| is greater than 180... there's a shorter path
    if ( abs($path) > 180 ) {
	$path -= ($path/abs($path))*360;    # Take the easy way.... but make
                                            # sure we get the direction right
    }

    my $badMove = $self->move_motor_relative($path);
    $path = &round($path);
    if ( $badMove != $path ) {
	warn "Unable to move motor to $angle: $badMove != " 
	    . $path . "!\n";
	return -1;
    }

    $self->block($angle);
    $position = $self->get_motor_int_degrees();
    return $position;
}

# Refuse to return until a move is completed
sub block {
    my ( $self, $angle ) = @_;

    my $handle = $self->{_filehandle};
    my $current_position = -1;

    while ( abs($current_position-$angle) > 1 ) {
	$motor->write("/1?0\r");
	my $current_steps = <$handle>;
	if ( !$current_steps ) {
	    usleep(50000);
	    next;
	}

	$current_steps =~ s/\r|\n//g;
	$current_steps =~ /.\/0(.)(\d+)/;

	# Motor returns /0@ while moving & /0` when stopped
	if ( $1 && $1 eq "`" ) {
	    last;
	}

	if ( $2 ) {
	    $current_position = $2/$steps_per_degree;
	}
	usleep(50000);
    }

    return;
}

sub set_status {
    my ( $self, $status ) = @_;
    $self->{_current_status} = $status;
    return;
}

sub get_status {
    my ( $self ) = @_;
    return $self->{_current_status} if $self->{_current_status} || undef;
}

sub reset_motor() {
    my ($self) = @_;

    if ( $self->{_test} ) {
	return;
    }

    my $handle = $self->{_filehandle};

    my $command = "/1T";
    $motor->write("$command\r");
    my $response = <$handle>;

    if ( $response =~ /0`/ ) {
	$response = "reset ok";
    } else {
	$response = "reset fail";
    }
    $self->{_current_status} = $response;
    if ( $response =~ /ok/i ) {
	$self->get_motor_int_degrees();
    }

    return $response;
}

sub init_motor() {
    my ($self) = @_;
    if ( $self->{_test} ) {
	return 0;
    }

    $self->{_current_status} = "initializing";

    my $handle = $self->{_filehandle};


    # Drop V (upper velocity)  to 10,000
    # Bump h (holding current) to 30 (default = 10%)
    my $command = "/1z0v200V10000L200j128m60h30R";
    $motor->write("$command\r");

    my $response = <$handle>;
    if ( $response =~ /0@/ ) {
	$response = "init ok";
    } else {
	$response = "init fail";
    }

    $self->{_current_status} = $response;
    if ( $response =~ /ok/i ) {
	$self->get_motor_int_degrees();
    }
    
    return $response;
}

sub check_angle() {
    my ($self, $angle) = @_;

    # Massage the angle(s) to be in [0,360]
    if ( $angle != -1 ) {
	while ( $angle < 0 ) {
	    $angle += 360;
	}
	if ( $angle > 360 ) {
	    $angle = $absolute%360;
	}
    }
    return $angle;
}

sub lock_motor() {
    # Before doing anything... make sure we're not locked...
    if ( -e "$home/motor.LCK" ) {
	print "Motor is currently in use. Please try again later\n";
	exit 1;
    } else {
	# The motor is available... lock it for our exclusive use
	`touch $home/motor.LCK`;
    }
    return;
}

sub unlock_motor() {
    # Remove the lock file on the motor
    if ( -e "$home/motor.LCK" ) {
	unlink("$home/motor.LCK");
    }
    return;
}

sub help {
    my ( $self, $msgID ) = @_;

    my $HR;

    $HR = "$msgID:MP     - Get current orientation of the CRiL\n$CRLF";
    $HR .= "$msgID:MV a   - Move a degrees from the current orientation, a = [-180, 180]$CRLF";
    $HR .= "$msgID:MA a   - Move to an angle of a degrees, a = [0, 360]$CRLF";
    $HR .= "$msgID:MR     - Reset the stepper motor$CRLF";
    $HR .= "$msgID:MI     - Initialize the stepper motor";

    return $HR if $HR || undef;
}


#=============================== End of Subs ===============================#

return 1;
