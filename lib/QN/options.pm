package procOptions;
#-------------------------------#
# This "package" provides only  #
# static methods to deal with   #
# configuring global switches   #
# It's purely for clarity in    #
# the main program and code     #
# separation for debugging      #
#-------------------------------#

use strict;
use warnings;

use Getopt::Long;
Getopt::Long::Configure('bundling', 'ignore_case');

use Net::CIDR;
use IO::Socket;
use POSIX qw(uname);

# System ID stuff
my $OS = $^O;                # Operating system (linux, darwin, Win32, etc.)
my $system = uname();        # POSIX uname system call.

# Program switches shared among threads & forks
my $continue   = 1;         # Stop signal = $continue = 0
my $verbose    = 1;         # Debugging toggle
my $localmode  = 0;         # Local access only, 1 client
my $password   = undef;     # Password for server access
my $workers    = 5;         # Minimum number of client threads in the pool
my $maxclients = 25;        # Maximum number of clients to accept
my $daemon     = 0;
my $apache_path;
my $use_ext_web;
my $cril       = 0;
my $motor      = "/dev/motor"; # CRiL stepper motor port

#----------------------------------------------------------#
#                   Semi-global variables                  #
#----------------------------------------------------------#
my $simulate  = 0;          # Don't try to talk to the card, just pretend
my $forward   = 0;          # Forward commands to other servers?

my $outdir;                 # Directory to save data file to

#----------------------------------------------------------#
#         Set the default device by OS type                #
#----------------------------------------------------------#
my @daqcard;
if ( $OS =~ /linux/i ) {
    my $device = undef;
    for ( my $i=0; $i<10; $i++ ) {
	if ( -c "/dev/ttyUSB$i" ) {
	    $device = "/dev/ttyUSB$i";
	    last;
	}
    }
    if ( $device ) {
	push(@daqcard,$device);
    } else {
	push(@daqcard, "/dev/daq");
    }
} elsif ( $OS =~ /darwin/i ) {
    push(@daqcard,"/dev/tty.SLAB_USBtoUART");

} elsif ( $OS =~ /MSWin/i ) { # Won't compile unless on Win32

    require Win32::TieRegistry;
    my $keyName = 'HKEY_LOCAL_MACHINE/HARDWARE/DEVICEMAP/SERIALCOMM/';
    my $machKey = new Win32::TieRegistry $keyName, { Delimiter => "/" };
    
    # Get a list of the available serial ports
    my @valueNames = $machKey->ValueNames();
    foreach my $name (@valueNames) {
	if ( $name =~ /Silabser/i ) {
	    my $port = $machKey->GetValue($name);
	    push( @daqcard, $port );
	    last;           # By default... only grab the first DAQ we find
	}
    }

    if ( $#daqcard == -1 ) {
	push(@daqcard, "COM5");
    }
}

my @whitelist = ();         # IP address filtering with the NET::CDIR module
my @blacklist = ();

my @forwdlist = ();         # List of "slave" servers

my $port     = 8979;        # Default port for client connections
my $webport  = 8008;        # Port for the web server to use
my $chatport = 8888;        # Port for the chat server application

my $optRef = {
    OS          => $OS,
    system      => $system,
    continu     => 1,
    verbose     => 1,
    port        => 8979,
    webport     => 8008,
    chatport    => 8888,
    localmode   => 0,
    webmod      => 0,
    password    => undef,
    workers     => 5,
    maxclients  => 25,
    simulate    => 0,
    daqcard     => \@daqcard,
    forward     => 0,
    daemon      => 0,

    cril        => 0,
    motor       => "/dev/motor",
    use_ext_web => 0,
    apache_path => undef,

    command     => undef,
    options     => [],

    whitelist   => [],
    blacklist   => [],
    forwdlist   => []

};

# Take the command line options, config 
# file, etc and process them
sub procOptions {

    my ( $doStartDump ) = @_;

    $doStartDump = ( defined($doStartDump) ) ? $doStartDump : 1;

    # Set up some OS dependent path here into the Environment hash
    $ENV{'USRHOME'} = ( $^O !~ /MSWin/i ) ? $ENV{'HOME'} : 
	$ENV{'HOMEPATH'} . "\\My\ Documents";

    $ENV{'USRDESK'} = ( $^O !~ /MSWin/i ) ? $ENV{'HOME'} . "/Desktop" : 
	$ENV{'APPDATA'} . "/Desktop";

    $ENV{'OURHOME'} = ( $^O !~ /MSWin/i ) ? $ENV{'HOME'} . "/.qncrd" :
	$ENV{'APPDATA'} . "\\QNCRD";

    $ENV{'SYSHOME'} = ( $^O !~ /MSWin/i ) ? "/etc/qncrd" :
	$ENV{'COMMONPROGRAMFILES'} . "\\QNCRD";

#---------------------------------------------------------------#
# Yet another @#W%(_@#% bend-over for M$ win(DOH!)$ inabilities #
#---------------------------------------------------------------#
    my $cmd;
    my @opt;
    if ( $^O =~ /MSWin/i ) {

	for ( my $i=0; $i<=$#ARGV; $i++ ) {
	    if ( $ARGV[$i] !~ /daemon/ ) {
		push(@opt, $ARGV[$i]);
	    }
	}
	push(@opt, "--no-daemon");
	push(@opt, "--no-verbose");

	require Cwd;
	my $path = Cwd::getcwd();
	$path =~ s/\//\\/g;
	$cmd = "perl \"$path\\$0\"";
    }
#---------------------------------------------------------------#

    my $config;
    my @wl = ();
    my @bl = ();
    my @fl = ();

    #----------------------------------------------------------#
    #     Options Hash: These are the command line switches    #
    #----------------------------------------------------------#
    my %getOptHash = (
	"help|h|?"      => \&usage,

	# Server options
	"verbose|v"     => \$verbose,
	"simulate|s"    => \$simulate,
	"daemon"        => \$daemon,
	"workers|w=i"   => \$workers,
	"max-clients=i" => \$maxclients,
	"forward"       => \$forward,
	"password|p=s"  => \$password,

	# Apache options
	"cril"          => \$cril,
	"motor=s"       => \$motor,
	"use-ext-web"   => \$use_ext_web,
	"apache-path=s" => \$apache_path, 

	# Toggle off options
	"no-verbose"    => sub { $verbose     = 0; },
	"no-simulate"   => sub { $simulate    = 0; },
	"no-forward"    => sub { $forward     = 0; },
	"no-ext-web"    => sub { $use_ext_web = 0; },
	"no-cril"       => sub { $cril        = 0; },
	"no-daemon"     => sub { $daemon      = 0; },

	# Allowed/rejected IP addresses & ranges
	"whitelist=s"   => \@wl,
	"blacklist=s"   => \@bl,
	"forwdlist=s"   => \@fl,

	# Configuration file
#	"file|f=s"      => \$config,  # Handled ourownselfs down below
	"output|o=s"    => \$outdir,

	# Hardware options
	"daq|d=s"       => sub {
	    my ( $option, $card ) = @_;

	    if ( $option !~ /^daq$|^d$/ ) {
		return -1;
	    }

	    $card =~ s/\"//g;
	    if ( $card =~ /\+$/ || $card =~ /^\+/ ) {
		$card =~ s/\+$//;
		$card =~ s/^\+//;
		if ( ! grep( /$card/, @daqcard ) ) {
		    push(@daqcard, $card);
		}
	    } else {
		@daqcard = ();
		push(@daqcard, $card);
	    }
	},

	"port|t=i"      => \$port,
	"web-port=i"    => \$webport,
	"chat-port=i"   => \$chatport,

	# Convienience options
	"local"         => \$localmode,

	# Handle unknown options
	"<>"            => sub { 
	    my ( $option ) = @_;
	    print "Unknown option $option ignored\n";
	}
	);

    #----------------------------------------------------------#
    #               Configuration file processing              #
    #----------------------------------------------------------#
    # See if we have a config file. Admittedly an odd way to deal
    # with things... but I want to allow the user to be able to
    # pass in a -f/--file switch in standard GetOpt form to specify
    # an arbitrary configuration file, yet still override the
    # options in the file from the command line.

    # Make a copy of ARGV to work from... just in case
    my @args = @main::ARGV;

    # Possibilities... -f <filename>, --file <filename>, 
    #                  -f<filename>,  --file=<filename>
    #
    for ( my $i=0; $i<=$#args; $i++ ) {

	if ( $args[$i] =~ /^-f/ ) {
	    # With the -f switch... we can have -f <name> or -f<name>
	    # See which one we've got...
	    if ( $args[$i] =~ /^-f$/ ) {
		$config = $args[eval($i+1)];
		splice(@args, $i, 2);
	    } else {
		$config = $args[$i];
		$config =~ s/-f//;
		splice(@args, $i, 1);
	    }

	} elsif ( $args[$i] =~ /^--file/ ) {
	    # The --file form can be --file <name> or --file=<name>
	    if ( $args[$i] =~ /^--file$/ ) {
		$config = $args[eval($i+1)];
		splice(@args, $i, 2);
	    } else {
		($config) = reverse(split(/=/,$args[$i]));
		splice(@args, $i, 1);
	    }
	}
    }

    # If everything went OK... copy the new argument list 
    # back to ARGV for GetOpt to process
    @main::ARGV = @args;
    undef @args;

    # If nothing was passed on the command line... go looking for it
    # Environment definitions from up above
    if ( !$config ) {
	if ( -r "qnserver.conf" ) {                       # Process level config
	    $config = "qnserver.conf";
	} elsif ( -r $ENV{'OURHOME'}."/qnserver.conf" ) { # User level config
	    $config = $ENV{'OURHOME'}."/qnserver.conf";
	} elsif ( -r $ENV{'SYSHOME'}."/qnserver.conf" ) { # System level config
	    $config = $ENV{'SYSHOME'}."/qnserver.conf";
	}
    }

    if ( $config && -r $config ) {   # We have a config file... read it in
	open(CONFIG, "<$config");
	my @options = <CONFIG>;
	chomp(@options);
	close( CONFIG );

	# Clean up whatever was passed in from $config 
	my $temp = join("\n",@options);

	# Step the first.... clean out any commentary
	$temp =~ s/\#.*//g;

	# Remove any blank lines
	$temp =~ s/^\n$//g;

	# And feed the results back into the options array
	@options = split("\n", $temp);

	# Go through each line and remove all the whitespace
	for ( my $i=0; $i<=$#options; $i++ ) {

	    $options[$i] =~ s/\s+//g;
	    chomp($options[$i]);

	    # If the result of removing whitespace & \n is
	    # a blank line then drop it, step back, and go 
	    # to the next line
	    if ( length($options[$i]) <= 0 ) {
		splice(@options, $i, 1);
		$i--;
	    }
	} # End for ( my $i=0; $i<=$#options; $i++ )

	# What we should have now is an array of opt=value
	# with no whitespace or EOL... so it's easy to handle
	for ( my $i=0; $i<=$#options; $i++ ) {
	    if ( $options[$i] =~ "=" ) {            # We have a switch to set
		my ($switch,$value) = split("=", $options[$i]);
		
		# Make the config file case insensitive
		$switch = lc($switch);
		$switch =~ s/\"//g;      # And get rid of quotes
		$value  =~ s/\"//g;

		# Allow the use of true/false & yes/no in the configuration
		if ( lc($value) eq "true" || lc($value) eq "yes" ) {
		    $value = "1";
		} elsif ( lc($value) eq "false" || lc($value) eq "no"  ) {
		    $value = "0";
		}

		if ( $switch eq "verbose" ) {
		    $verbose = atoi($value);
		} elsif ( $switch eq "simulate" ) {
		    $simulate = atoi($value);
		} elsif ( $switch eq "daemon" ) {
		    $daemon = atoi($value);

		} elsif ( $switch eq "daqdevice" ) {

		    # Format thing... if the device name includes a
		    # + then add it to the list of DAQs to monitor
		    # otherwise, flush the list & use this device
		    # as the only one
		    if ( $value =~ /\+$/ || $value =~ /^\+/ ) {
			$value =~ s/\+$//;
			$value =~ s/^\+//;
			if ( ! grep( /$value/, @daqcard ) ) {
			    push(@daqcard, $value);
			}
		    } else {
			@daqcard = ();
			push(@daqcard, $value);
		    }

		# Output directory
		} elsif ( $switch eq "output" ) {
		    $outdir = $value;

		# Switch for using this with the CRiL
		} elsif ( $switch eq "cril" ) {
		    $cril = atoi($value);

		# USB-to-Serial port for the CRiL Motor
		} elsif ( $switch eq "motor" ) {
		    $motor = $value;

		# Switch to enable dynamic update for external web servers
		} elsif ( $switch eq "use-ext-web" ) {
		    $use_ext_web = atoi($value);

		# Path to apache web server directory 
		# if not using built-in web-server
		} elsif ( $switch eq "apache-path" ) {
		    $apache_path = $value;

		# Ports to open
		} elsif ( $switch eq "port" ) {
		    $port = atoi($value);
		} elsif ( $switch eq "web-port" ) {
		    $webport = atoi($value);
		} elsif ( $switch eq "chat-port" ) {
		    $chatport = atoi($value);

		} elsif ( $switch eq "forward" ) {
		    $forward = atoi($value);
		} elsif ( $switch eq "password" ) {
		    $password = $value;
		} elsif ( $switch eq "workers" ) {
		    $workers = atoi($value);
		} elsif ( $switch eq "maxclients" ) {
		    $maxclients = atoi($value);
		}

	    } # End if ( $options[$i] =~ "=" )
	    else {

		# OK... that was the easy part....
		# Now deal with the whitelist/blacklist options
		if ( $options[$i] =~ /list/ ) {

		    # Scan through the options list until we find
		    # the closing brace for this list
		    my $j = $i + 1;
		    while ( $options[$j] !~ /}/ ) {
			$j++;
		    }

		    # Roll through the options from the begining
		    # of this list to the close and add any IP
		    # addresses we find
		    for ( my $k=$i+1; $k<$j; $k++ ) {
			
			if ( $options[$i] =~ /white/ ) {
			    push( @whitelist, $options[$k]);
			} elsif ( $options[$i] =~ /black/ ) {
			    push( @blacklist, $options[$k] );
			} elsif ( $options[$i] =~ /forwd/ ) {
			    push( @forwdlist, $options[$k] );
			} else {
			    $options[$i] =~ s/{//;
			    warn "Unknown IP list type: $options[$i]\n";
			}

		    } # End for ( my $k=$i+1; $k<$j; $k++ )
		    
		} # End if ( $options[$i] =~ /list/ )

	    } # End else { !$options[$i] =~ "=" }

	} # End for ( my $i=0; $i<=$#options; $i++ )

    } # End if ( $config )

    #
    #----------------------------------------------------------#
    #           Get basic options from the command line        #
    #           call #2: overrides defaults & config file      #
    #           with any options from the command line         #
    #----------------------------------------------------------#
    #
    GetOptions( %getOptHash);

    foreach my $address (@wl) {
	push(@whitelist, $address);
    }
    foreach my $address (@bl) {
	push(@blacklist, $address);
    }
    foreach my $address (@fl) {
	push(@forwdlist, $address);
    }

    # If we're daemonizing... turn off the verbosity
    if ( $daemon ) {
	$verbose = 0;
    }

    # Make sure our min/max make sense
    if ( $workers > $maxclients ) {
	$workers = $maxclients;
    }

    # If we got a "~" in the output directory... 
    # exchange it for $HOME
    if ( $outdir =~ /\~/ ) {
	my $home = $ENV{'HOME'};
	$outdir =~ s/\~/$home/;
    }

    # Make sure we know where we're supposed to save data, 
    # and that we can successfully write/read in that directory
    if ( $outdir ) {
	my $testFile = $outdir . "/test.dat";
	open(my $fh, ">$testFile") or 
	    warn "Unable to write to directory " . $outdir . ": $!";

	if ( fileno($fh) ) {
	    print $fh "This is a test\n";
	    close($fh);

	    open( $fh, "<$testFile") or
		warn "Unable to open " . $outdir . ": $!";
	    if ( fileno($fh) ) {
		my $read = <$fh>;
		if ( $read =~ /This is a test/ ) {
		    close($fh);
		    $ENV{'OUTDIR'} = $outdir;
		}
	    }
	    unlink($testFile) if (-e $testFile);
	}
    }

    if ( !defined($ENV{'OUTDIR'}) ) {
	$ENV{'OUTDIR'} = $ENV{'USRHOME'};
	$outdir = $ENV{'OUTDIR'};
    }

    if ( $use_ext_web ) {
	if ( !(-d $apache_path) ) {
	    $use_ext_web = 0;
	}
    }

    # If we're running in verbose mode... dump out our startup options
    if ( $verbose && $doStartDump ) {
	startUpDump();
    }

    # All done configuring.... fill the 
    # option hash and return it to main
    $optRef = {
	OS           => $OS,
	system       => $system,
	continu      => $continue,
	verbose      => $verbose,
	port         => $port,
	webport      => $webport,
	chatport     => $chatport,
	localmode    => $localmode,
	password     => $password,
	workers      => $workers,
	maxclients   => $maxclients,
	simulate     => $simulate,
	daqcard      => \@daqcard,
	forward      => $forward,
	daemon       => $daemon,
	outdir       => $outdir,
	cril         => $cril,
	motor        => $motor,
	use_ext_web  => $use_ext_web,
	apache_path  => $apache_path,

	command      => $cmd,
	options      => \@opt,

	whitelist    => \@whitelist,
	blacklist    => \@blacklist,
	forwdlist    => \@forwdlist
    };

    return $optRef;
} # End procOptions

sub startUpDump {

    # If we're running in verbose (debug) mode... announce our startup options
    print "Server starting up on $OS ($system) with options :\n";
    print "\tsimulate    = " . (($simulate)  ? "true\n" : "false\n");
    print "\tforward     = " . (($forward)   ? "true\n" : "false\n");
    print "\tOutput      => $outdir\n";

    print "\tDAQ device  = " . join(",",@daqcard) . "\n";
    if ( $cril ) {
	print "\tMotor port  = $motor\n";
    }

    print "\tServer port = $port\n";
    print "\tMax Clients = $maxclients\n";

    if ( $use_ext_web ) {
	print "\tUpdating apache page at " . $apache_path , "\n";
    }

    if ( $#whitelist > -1 || $#blacklist > -1 ) {
	
	if ( $#whitelist > -1 ) {
	    print "White listed addresses : \n\t";
	    print join("\n\t", @whitelist) . "\n";

	}
	if ( $#blacklist > -1 ) {
	    print "Black listed addresses : \n\t";
	    print join("\n\t", @blacklist) . "\n";
	}
    } else {
	print "\tDefault access from localhost only\n";
    }

    if ( $forward && $#forwdlist > -1 ) {
	print "Server set as master: Forwarding commands to\n\t";
	print join("\n\t", @forwdlist) . "\n";
    }

    return;
}

# Convert strings to integers
sub atoi {

  my $isNegative = 0;
  my $t = 0;
  if ( index($_[0], "-") == 0 ) {
    $isNegative = 1;
    my @temp = split(/\-/,$_[0]);
    $_[0] = $temp[1];
  }

  foreach my $d (split(//, shift())) {
    $t = $t * 10 + $d;
  }
  if ( $isNegative > 0 ) {
    $t = -1 * $t;
  }
  return $t;

}


# Simple terminal dump of program usage... helpful ain't it?
sub usage {

    print "Usage: $0 <options>\n";

    print "\tCommand line options:\n\n";

    # Server options
    print "\tverbose|v\tMake lots of debugging noises\n";
    print "\tsimulate|s\tRun a simulation of the DAQ card\n";
    print "\tdaemon\t\tFork off (into the background)\n";
    print "\tworkers|w=i\tNumber of worker threads in the servers pool\n";
    print "\tmax-clients=i\tMaximum number of active connections\n";
    print "\tforward\t\tEnable forwarding of commands to other servers\n";
    print "\tpassword|p=s\tRequire a password to access the DAQ\n\n";

    # Apache options
    print "\tcril\t\tEnable CRiL extensions\n";
    print "\tmotor=s\t\tDevice name/COM Port the CRiL motor is connected to\n";
    print "\tuse-ext-web\tEnable external (apache) web server updates\n";
    print "\tapache-path=s\tPath to the files for the external web server\n\n";

    # Toggle off options
    print "\tno-verbose\tOverride config and shut the program up\n";
    print "\tno-simulate\tOverride config and don't simulate\n";
    print "\tno-forward\tOverride config and don't forward\n";
    print "\tno-ext-web\tOverride config and disable apache extension\n";
    print "\tno-cril\t\tOverride config and disable CRiL extensions\n";
    print "\tno-daemon\tOverride config and don't fork\n\n";

    # Allowed/rejected IP addresses & ranges
    print "\twhitelist=s\tIP ranges to allow: adds to list in config\n";
    print "\tblacklist=s\tIP ranges to block: adds to list in config\n";
    print "\tforwdlist=s\tOther servers to forward to: adds to list in config\n\n";

    # Configuration file
    print "\tfile|f=s\tConfiguration file to read options from\n";

    # Data saving
    print "\toutput|o=s\tPath where data files will be saved to\n\n";

    # Hardware options
    print "\tdaq|d=s\t\tDevice name of the DAQ to use.(+ adds to the list)\n";
    print "\tport|t=i\tPort number the server should listen on  (8979)\n";
    print "\tweb-port=i\tPort number the built-in web server uses (8008)\n";
    print "\tchat-port=i\tPort number for the built-in chat server (8888)\n\n";

    # Convienience options
    print "\tlocal\t\tConvienience option, enables \"local\" mode\n";

    exit 0;
}
return 1;
