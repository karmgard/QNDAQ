#!/usr/bin/perl
#----------------------------------------------------------------#
# cardServer.pl : Middleware pipeline bridging a TCP socket to a #
#                 QuarkNet DAQ card on a Serial/USB line. Awaits #
#                 commands on a network socket (from a browser,  #
#                 or telnet, or a custom interface, or anything  #
#                 that knows how to open up a socket). Checks    #
#                 the input and enqueues (serializes) it. The    #
#                 card is dealt with in the background so that   #
#                 slow I/O doesn't block the front end from      #
#                 other tasks. Replies are sent back to the      #
#                 the originating client or (optionally) broad-  #
#                 cast to all connected clients.                 #
#                 This script uses mostly stock perl modules,    #
#                 and includes the non-standard modules it needs #
#                 so it should run on any basic installation     #
#                 without having to install any additional perl  #
#                 modules/libraries/etc.                         #
#                                                                #
# Version 0.13    14 Feb 11              Dan Karmgard            #
#                                                                #
#                                                                #
# Version 0.14    19 Mar 11              Dan Karmgard            #
#                                                                #
# Added web services. Includes a stand-alone web server, stand-  #
# alone chat server (IRC style), a Flash policy server, and a    #
# basic web page as proof of concept. Many bug fixes as well.    #
#                                                                #
#  Version 0.15    28 Mar 11             Dan Karmgard            #
#                                                                #
# More cleanups, alterations of the program structure so that it #
# will run on any system with PERL installed, including MSWin32. #
# And that was no small feat! Minor modifications so that the    #
# program can be packaged with PAR::Packer and distributed to    #
# any computer and run even if it has never seen perl            #
#                                                                #
#  Version 0.16    10 Apr 11             Dan Karmgard            #
#                                                                #
# Various server routines broken into seperate programs so they  #
# can be started/stopped individually. Necesary since starting   #
# the flash server requires root privileges but we don't want    #
# the entire program running as root. Network based installer    #
# for Mac OSX & Linux. Still not quite sure how to manage that   #
# on windows machines without wget/curl installed.               #
#                                                                #
#  Version 0.17    21 Apr 11             Dan Karmgard            #
#                                                                #
# CRiL Extensions built in to the main server. Can now access    #
# the motor straight through the main server.                    #
#                                                                #
#  Version 0.17.1  28 Apr 11             Dan Karmgard            #
#                                                                #
# Cleanups, bug fixes, testing, and some small utility routines  #
# added. Setup utility to handle minor differences between OS's  #
# I think it's about ready to go to beta                         #
#----------------------------------------------------------------#
#

our $VERSION = 0.17.1;

use lib qw(lib);             # Location of the odd modules written/included
                             # Can also, from a bash shell or .bash_profile,
                             # do an export PERL5LIB=$PERL5LIB:/path/to/lib

use strict;
use warnings;
use Config;

use QN::options;
use QN::server;

$Config{useithreads} or 
    die "This program requires Perl with threads in order to run\n";

# Global stop/shutdown signal
my $continue = 1;
$SIG{'STOP'} = sub{ $continue = 0; };

# Process the config file & command line options
# Routine is located in lib/QN/options.pm for clarity
# It returns a reference to a hash of options
my $optRef = procOptions::procOptions();

if ( $optRef->{daemon} ) {     # Auto-fork into the background

    if ( $^O =~ /MSWin32/i ) {   # If this is a winders machine....
	                         # WHAT THE @#_%)($@# WERE YOU THINKING!?!
	my $pid = system(1, $optRef->{command}, @{$optRef->{options}});
	exit 0;
    } else {                     # Run this same thing on a sensible system
	my $pid = fork();
	if ( !defined($pid) ) {
	    die "screaming: $!\n";
	} elsif ( $pid ) {
	    exit 0;
	}

	# If we're background... don't make any noise
	$optRef->{verbose} = 0;
    }
}


# Run in local mode only -- One client at a time from localhost
if ( $optRef->{localmode} ) {
    $optRef->{whitelist} = $optRef->{blacklist} = $optRef->{forwdlist} = ();
    $optRef->{forward}  = 0;
    $optRef->{workers}  = 1;
}

# Start a new network server listening on Port $port
my $server = new server($optRef);

# If there's an associated apache server AND we've got a password
# dump it out so the apache server can find it easily
my $apache_path = $optRef->{apache_path};
if ( $apache_path && $optRef->{password} ) {
    if ( -d $apache_path && -w $apache_path ) {
	my $path = $apache_path . "/.htpasswd";

	if ( $optRef->{verbose} ) {
	    print STDERR "Updating $path\n";
	}

	# Handle the password file .htpasswd -- by default
	# apache won't serve any file that begins with .ht
	open(FH, ">$path") || 
	    warn "Unable to send password to apache: $!\n";
	print FH $optRef->{password} . "\n";
	close(FH);

	# Update the crossdomain.xml file for flash security policy
	$path = $apache_path . "/crossdomain.xml";

	open(FH, "<$path") || warn "Unable to update $path: $!\n";
	my @lines = <FH>;
	chomp(@lines);
	close(FH);

	if ( $optRef->{verbose} ) {
	    print STDERR "updating crossdomain.xml\n";
	}

	# Save a backup copy just in case (done with a
	# raw write so we don't have to import File::Copy
	# just for these couple lines)
	open(BK, ">$path~");
	print BK join("\n", @lines) . "\n";
	close(BK);

	foreach my $line (@lines) {
	    if ( $line =~ /to-ports/ ) {
		my $update = "to-ports=\"" . $optRef->{port} .
		    "," . $optRef->{chatport} . "\"\/\>\n";
		$line =~ s/to-ports.*$/$update/;
	    }
	}
	open(FH, ">$path");
	print FH join("\n", @lines);
	close(FH);
	
	# Update the port numbers for jsocket, these are found
	# in functions.js near the top as var cardPort & var chatPort
	$path = $apache_path . "/functions.js";
	open(FH, "<$path") || warn "Unable to update $path: $!\n";
	@lines = <FH>;
	chomp(@lines);
	close(FH);

	if ( $optRef->{verbose} ) {
	    print STDERR "updating javascript\n";
	}

	# Save a backup copy just in case (done with a
	# raw write so we don't have to import File::Copy
	# just for these couple lines)
	open(BK, ">$path~");
	print BK join("\n", @lines) . "\n";
	close(BK);

	foreach my $line (@lines) {
	    if ( $line =~ /var cardPort/ ) {
		my $update = "cardPort = " . $optRef->{port} . ";";
		$line =~ s/cardPort.*$/$update/;
	    } elsif ( $line =~ /var chatPort/ ) {
		my $update = "chatPort = " . $optRef->{chatport} . ";";
		$line =~ s/chatPort.*$/$update/;
	    }
	}
	open(FH, ">$path");
	print FH join("\n", @lines);
	close(FH);
	##########################################################

    } elsif ( $optRef->{verbose} ) {
	print "Unable to update apache files\n";
    }
}

# Start the I/O queues
$server->startQueues() || die "Unable to start I/O queues: $@\n";

# See if we're forwarding
if ( $optRef->{forward} && $#{$optRef->{forwdlist}} > -1 ) {
    $server->startClients();
}

# Start up the thread pool
$server->startThreadPool($optRef->{workers}, 
			 $optRef->{workers}, 
			 $optRef->{verbose}) || 
    die "Unable to start thread pool: $@\n";

# Start the server main loop
$server->mainLoop();

# Clean up the mess
$continue = 0;

# We're done... exit quietly
exit 0;
