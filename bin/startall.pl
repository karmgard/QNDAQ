#!/usr/bin/perl

use strict;
use warnings;

if ( $^O !~ /MSWin/i ) {
    system("/usr/bin/sudo bin/flashPolicyServer.pl");
    system("./cardServer.pl");
    system("bin/chatServer.pl");
    system("bin/webserver.pl");
} else {
    system("perl cardServer.pl");
    system("perl bin/flashPolicyServer.pl");
    system("perl bin/chatServer.pl");
    system("perl bin/webserver.pl");
}
exit 0;
