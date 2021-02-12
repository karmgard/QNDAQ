#!/usr/bin/perl

use strict;
use warnings;

use IO::Socket;

my $CRLF = "\015\012";  # \r\n
my $CR   = "\015";      # \r
my $LF   = "\012";      # \n

my $cardPort = 8979;
my $chatPort = 8888;
my $verbose  = 0;
my $daemon   = 0;

use lib qw(lib);
use QN::options;

my $optHash = procOptions::procOptions(my $doStartDump = 0);

$cardPort = $optHash->{port};
$chatPort = $optHash->{chatport};
$verbose  = $optHash->{verbose};
$daemon   = $optHash->{daemon};

if ( $daemon ) {

    if ( $^O =~ /MSWin32/i ) {   # If this is a winders machine....
	                         # WHAT THE @#_%)($@# WERE YOU THINKING!?!
	my $pid = system(1, $optHash->{command}, @{$optHash->{options}});
	exit 0;
    } else {                     # Run this like a sensible system

	my $pid = fork();
	if ( !defined($pid) ) {
	    die "Screaming!\n";
	} elsif ( $pid ) {
	    exit 0;
	}

	# If we're background... don't make any noise    
	$verbose = 0;
    }

}


# Get our policy for cross-domain scripting
# And the modification time on the file so
# we can monitor it for changes as we go
my $policyFile = &findXDomain();
my $timestamp  = getXDomainModTime($policyFile);
my $policy     = readPolicy($policyFile);

#----------------------------------------------------------------#
# By default... flash looks for a cross-domain scripting policy  #
# at the server root, then on port 843, if it can't find  it     #
# there it will then check the port that the application is      #
# attempting to open. So opening a policy server here is much    #
# more efficient since jsocket apps don't have to wait for a     #
# timeout on 843, but it requires root privileges... which       #
# raises a whole host of red flags. So.... if this server has    #
# root privileges, then go ahead an open a server on 843, other- #
# wise handle policy requests in the main server on the port it  #
# is listening to.                                               #
#----------------------------------------------------------------#

my $flashSecurity = IO::Socket::INET->new(
    Proto     => 'tcp',
    LocalPort => 843,    # Privileged port. Needs root access
    Listen    => SOMAXCONN,
    ReuseAddr => 1
    );
if ( not defined $flashSecurity ) {
    die "Security port open fail: $!\n";
}

$flashSecurity->autoflush( 1 );

if ( $verbose ) {
    print "Opened port 843 for security policy requests\n";
}

$SIG{'INT'} = $SIG{'TERM'} = $SIG{'STOP'} = sub{
    if ( $verbose ) {
	print "Caught kill... flash server shutting down\n";
    }

    $flashSecurity->close();
    undef $flashSecurity;
    exit 0;
};

$flashSecurity->autoflush(1);

# Set the line terminator to the null char -- stoopid adobe
$/ = "\0";
while ( my $client = $flashSecurity->accept() ) {

    my $ip = join( ".", unpack('C4', $client->peeraddr) );
    if ( $verbose ) {
	print "Connection to policy server from $ip\n";
    }

    $client->autoflush(1);
#    my $request = <$client>;

    #--------------------------------------------------------#
    # Read loop: Carefully read from the socket until we get #
    # a line terminator, 32 bytes, or more than 2s between   #
    # characters so we don't risk buffer overflows and such  #
    #--------------------------------------------------------#
    # Stall counter... throw a timeout if no characters in 10s
    my $sleepy = 25000;
    my $STALL_TIMEOUT = 2000000;
    my $timer = 0;
    my $inbuff = "";
    while ( $inbuff !~ /\0/ && length( $inbuff ) < 32 ) {

	my $isAlive = $client->sysread( $inbuff, 32, length( $inbuff ) );

	if ( !defined($isAlive) ) {   # Tried to read... got bupkis
	    usleep($sleepy);
	    $timer += $sleepy;

	    if ( $timer >= $STALL_TIMEOUT ) {
		print $client "\0Timeout\0";
		$inbuff = undef;
		last;
	    }

	} elsif ( $isAlive == 0 ) {   # Got a response: dead connection
	    if ( $verbose ) {
		print "Lost connection with $ip\n";
	    }
	} else {
	    $timer = 0;
	}
    }

    if ( !$inbuff ) {
	close($client);
	next;
    }

    my $request = $inbuff;

    if ( $verbose ) {
	print "Got $request on 843 from $ip\n";
    }

    if ( $request =~ /.*policy-file.*/i ) {
	&sendPolicy($client, $cardPort, $chatPort, $verbose, $ip);
    } elsif ( $request =~ /done/i ) {
	last;
    }
    
    close($client);
}

$flashSecurity->close();
undef $flashSecurity;
exit 0;

#-----------------------------------------------------------#
#  Go looking for a cross-domain.xml in the usual places    #
#-----------------------------------------------------------#
sub findXDomain {

    if ( -r "crossdomain.xml" ) {
	$policyFile = "crossdomain.xml";

    } elsif ( -r "html/crossdomain.xml" ) {
	$policyFile = "html/crossdomain.xml";

    } elsif ( -r $ENV{'OURHOME'} . "/html/crossdomain.xml" ) {
	$policyFile = $ENV{'OURHOME'} . "/html/crossdomain.xml";

    } elsif ( -r $ENV{'SYSHOME'} . "/html/crossdomain.xml" ) {
	$policyFile = $ENV{'OURHOME'} . "/html/crossdomain.xml";
    } else {
	$policyFile = undef;
    }

    if ( !$policyFile ) {
	if ( $verbose ) {
	    print "Using built-in default cross-domain policy\n";
	}
    } elsif ( $verbose ) {
	print "Using cross-domain policy from $policyFile\n";
    }
    return $policyFile;
}

sub getXDomainModTime {
    my ( $policyFile ) = @_;

    if ( !$policyFile ) {
	return undef;
    }

    open ( FH, "<$policyFile" ) || warn "Unable to read policy file!: $!\n";
    my @status = stat(FH);
    my $modTime = $status[9];
    close(FH);

    return $modTime;
}

sub readPolicy {
    my ($policyFile) = @_;

    # Default policy
    my $policy = qq(<?xml version="1.0"?>\n<!DOCTYPE cross-domain-policy SYSTEM\n"http://www.adobe.com/xml/dtds/cross-domain-policy.dtd">\n<cross-domain-policy>\n<allow-access-from domain="*" to-ports="8979,8888"/>\n</cross-domain-policy>\0);
    if ( !$policyFile ) {
	return $policy;
    }

    open(PH, "<$policyFile");
    if ( !fileno(PH) ) {
	warn "Unable to open $policyFile for read: $!\n";
	return $policy;
    }

    my @policy_from_file = <PH>;
    close(PH);
    if ( $#policy_from_file < 0 ) {
	warn "Read failed on $policyFile: $!\n";
	return $policy;
    }

    return join("", @policy_from_file);
}

#-----------------------------------------------------------#
#            Send the cross-domain policy           #
#-----------------------------------------------------------#
#
sub sendPolicy {       # static method for sending flash cross-domain
                       # security policy to a browser through a socket
    my ($client,$cardport,$chatport,$verbose,$ip) = @_;

    # We should already have a policy... if it's from a file, check if
    # that file has changed since we read it in
    if ( $timestamp != &getXDomainModTime($policyFile) ) {
	$policy = readPolicy($policyFile);
	$timestamp = getXDomainModTime($policyFile);

	if ( $verbose ) {
	    print "$policyFile changed on disk. Rereading\n";
	}
    }

    # Make sure we're permitting access to the proper ports
    $policy =~ s/8979/$cardport/;
    $policy =~ s/8888/$chatport/;

    if ( $client ) {

	$client->autoflush();
	print $client $policy;

	if ( $verbose ) {
	    print STDOUT "Sent policy file to client at $ip\n";
	}

    } else {
	warn "Client? What client!\n";
    }

    return;
}
