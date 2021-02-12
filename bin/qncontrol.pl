#!/usr/bin/perl

use strict;
use warnings;

use lib qw(lib);

use QN::daq;
use QN::gui;

#
#
# Instantiate a new instance of the DAQ library module
my $daq = new daq();

# And the perl/Tk GUI
my $gui = new gui($daq);

# Run the main loop -- Hangs here until user presses "Exit"
$gui->runMainLoop();

# We're done... shut down the serial port & close up
$daq->shutdown();

exit 0;
