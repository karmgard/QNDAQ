#!/usr/bin/perl

use strict;
use warnings;

use POSIX qw(uname);
use File::Copy;
use File::Path;
use Cwd;

# System identification stuff
my $os = $^O;
my $arch = POSIX::uname();

# Make sure we know where we are
my $base = getcwd();

# Win32 edit to lib\QN\options.pm ..... No longer necessary 28 Apr 11
#if ( $os =~ /MSWin/i ) {
#    my $edit = "lib\\QN\\options.pm";
#    open( IH, "<$edit" )   || die "Unable to make edits to $edit: $!\n";
#    open( OH, ">test.pm" ) || die "Unable to open output file: $!\n";
#    while ( my $line = <IH> ) {
#	if ( $line =~ /MSWin/ && $line =~ /\#/ ) {
#	    $line =~ s/\#//;
#	    print OH $line;
#	    while ( $line = <IH> ) {
#		if ( $line !~ /\#/ ) {
#		    last;
#		}
#		$line =~ s/\#//;
#		print OH $line;
#	    }
#	}
#	print OH $line;
#    }

#    close(IH);
#    close(OH);

#    move( $edit, "$edit.bak" ) || 
#	die "Unable to make a backup of $edit: $!\n";
#    move( "test.pm", $edit )   || 
#	die "Unable to move new module into place: $!\n";
#    print "All done\n";
#    exit 0;
#}

# For Mac/Linux systems try and find the proper serial port library
my $symlink = "lib/auto/Device/SerialPort/SerialPort.so";
if ( -l $symlink ) {
    unlink($symlink);
}

# First... see if the user has Device::SerialPort installed
my $testCmd = 'perl -MDevice::SerialPort -e \'print "\n";\' > /dev/null 2>&1';
my $result = system($testCmd);

if ( $result == 0 ) {
    # It's install and it's good

    print "Setup completed successfully.\n";
    print "Using Device::SerialPort installed on the system\n";

    exit 0;
}

# Well .... nuts.... Device::SerialPort isn't here
# See if we've got a decent version for this system
my $libname = "lib/auto/Device/SerialPort/SerialPort.$os.$arch.so";
if ( -f $libname ) {
    my $symlink_exists = eval { symlink("",""); 1 };

    # System supports symbolic linking...
    if ( $symlink_exists ) {

	if ( $os =~ /linux/ ) {
	    $symlink = "SerialPort.so";
	} elsif ( $os =~ /darwin/ ) {
	    $symlink = "SerialPort.bundle";
	}
	$result = symlink($libname, $symlink);
	$result += symlink("lib/Device/SerialPort.pm", "SerialPort.pm");
	    
	if ( $result == 2 ) {
	    # Got the link... Try and use it
	    my $test2 = 'perl -MSerialPort -e \'print "\n";\'';
	    my $result = system($test2);
	    if ( $result == 0 ) {
		# Worked... link the library, clean up and exit
		$result = symlink("SerialPort.$os.$arch.so", 
				  "lib/auto/Device/SerialPort/" . $symlink);

		if ( $result == 0 ) {
		    warn "Unable to link to $libname: $!\n";
		    exit 2;
		}
		unlink("SerialPort.pm");
		unlink($symlink);

		print "Setup completed successfully.\n";
		print "Using included Device::SerialPort\n";
		exit 0;
	    }
	} else {
	    warn "Error linking to SerialPort.$os.$arch.so: $!\n";
	    exit 1;
	}

    } # End if ( $symlink_exists ) {
} # End if ( -f $libname ) {

# Sigh... if we got all the way here then nothing's worked
# See if we can compile a version of Device::SerialPort
# suitable for this system
print "Unable to find a suiable Device::SerialPort. Attempting to build one\n";

my $release = "Device-SerialPort-1.04";

# See if we can grab the release we use and inflate the tarball
chdir("lib/Dist/") || die "Can't find the lib/Dist directory: $!\n";
mkdir("tmp") || die "Can't make tmp/ directory: $!\n";
chdir("tmp/") || die "Can't change to the lib/Dist/tmp/ directory: $!\n";
$result = system("tar -zxf ../$release.tar.gz");
if ( $result ) {
    die "Can't unzip the tarball: $!\n";
}
chdir("$release/") || die "Can't change to $release directory: $!\n";

# So.. we've got the code... see if we can make the Makefile
$result = system("perl Makefile.PL");
if ( $result != 0 ) {
    die "Failed to run Makefile.PL: $!\n";
}

# Looks good so far... Try making the library
$result = system("make");
if ( $result != 0 ) {
    die "Unable to make $release: $!\n";
}

# Seemed to work... Did it?
if ( !(-e "SerialPort.pm") ) {
    die "Failed to make SerialPort.pm ... huh? : $!\n";
}

my $library = "blib/arch/auto/Device/SerialPort/SerialPort.so";
if ( !(-x $library) ) {
    die "Failed to make $library: $!\n";
}
copy($library, ".") || die "Failed to copy $library: $!\n";

# OK... so it seems we have a brand spanking new Device::SerialPort
# Try it out and see if everything went the way it should have
my $test3 = 'perl -MSerialPort -e \'print "\n";\'';
$result = system($test3);

if ( $result == 0 ) {
    # Worked... link the library, clean up and exit

    copy("SerialPort.so", 
	 "$base/lib/auto/Device/SerialPort/SerialPort.$os.$arch.so") ||
	     die "Failed to copy library: $!\n";
    copy("SerialPort.pm", "$base/lib/Device/") ||
	die "Failed to copy module: $!\n";

    # Clean up the mess in the temp directory
    chdir("$base/lib/Dist") || 
	die "Unable to change directory: $!\n";

    rmtree("tmp/") || 
	warn "Failed to remove directory lib/Dist/tmp/ $!\n";

    chdir($base) || die "Unable to change directory to $base: $!\n";

    # Make sure we support symbolic links
    my $symlink_exists = eval { symlink("",""); 1 };

    # System supports symbolic linking...
    if ( $symlink_exists ) {
	# establish the proper links
	$library = "SerialPort.$os.$arch.so";
	$result = symlink($library, $symlink);
	if ( $result == 0 ) {
	    warn "Unable to symlink to the new library. copying to SerialPort.so: $!\n";
	    copy($library, $symlink) || 
		warn "Can't even do that: $!. Please cd lib/auto/Device/SerialPort;cp $library $symlink\n";
	}
    } else {
	warn "Your system does not support symbolic links. Hard copying the new library\n";
	copy($library, $symlink) || 
	    warn "Can't even do that: $!. Please cd lib/auto/Device/SerialPort;cp $library $symlink\n";
    }

    # Got it! And everything worked no less! 
    print "Setup completed successfully.\n";
    print "Using newly compiled Device::SerialPort in lib/\n";
    print "Please send this library to the maintainer to be included\n";
    print "in future releases of this software package\n";

    exit 0;
}

# Well crap! Nothing worked... Bitch & moan and
# tell the user it failed
print "Unable to successfully find or build Device::SerialPort.\n";
print "Please notify the maintainer of this problem.\nSorry about that.\n";

exit 5;
