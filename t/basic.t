#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use IO::Pty::Easy;

my $pty = IO::Pty::Easy->new(handle_pty_size => 0);

my $script = <<'SCRIPT';
use strict;
use warnings;
use Term::Filter::Callback;
my $term = Term::Filter::Callback->new;
$term->run($^X, '-ple', q[last if /^$/]);
print "done\n";
SCRIPT

my $crlf = "\x0d\x0a";

$pty->spawn($^X, (map { "-I $_" } @INC), '-e', $script);

# just in case
alarm 60;

$pty->write("foo\n");
is($pty->read(undef, 5), "foo$crlf");
is($pty->read(undef, 5), "foo$crlf");
$pty->write("bar\nbaz\n");
is($pty->read(undef, 5), "bar$crlf");
is($pty->read(undef, 5), "baz$crlf");
is($pty->read(undef, 5), "bar$crlf");
is($pty->read(undef, 5), "baz$crlf");
$pty->write("\n");
is($pty->read(undef, 2), "$crlf");
is($pty->read(undef, 6), "done\n");

done_testing;
