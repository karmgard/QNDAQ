#!/usr/bin/perl

use CGI;
my $cgi = new CGI();

open(FH, "<.htpasswd");
my ($password) = <FH>;
close(FH);
chomp($password);

my $passwd = $cgi->param('passwd');

my $result = "fail";
if ( $passwd eq $password ) {
    $result = "success";
}

print $cgi->header("Content-type: text/xml");
print "<data>$result</data>";
