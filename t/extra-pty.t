#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use File::Temp 'tempdir';
use File::Spec;
use IO::Pty::Easy;
use IO::Select;
use POSIX ();

my $dir = tempdir(CLEANUP => 1);
my $readp = File::Spec->catfile($dir, 'read');
my $writep = File::Spec->catfile($dir, 'write');
POSIX::mkfifo($readp, 0700)
    or die "mkfifo failed: $!";
POSIX::mkfifo($writep, 0700)
    or die "mkfifo failed: $!";

my $script = <<SCRIPT;
use strict;
use warnings;
use Term::Filter::Callback;
open my \$readfh, '<', '$readp'
    or die "can't open pipe (child): \$!";
open my \$writefh, '>', '$writep'
    or die "can't open pipe (child): \$!";
my \$term = Term::Filter::Callback->new(
    callbacks => {
        setup => sub {
            my (\$t) = \@_;
            \$t->add_input_handle(\$readfh);
        },
        read => sub {
            my (\$t, \$fh) = \@_;
            if (\$fh == \$readfh) {
                my \$buf;
                sysread(\$fh, \$buf, 4096);
                if (defined(\$buf) && length(\$buf)) {
                    print "read from pipe: \$buf\\n";
                }
                else {
                    print "pipe error (read)!\\n";
                    \$t->remove_input_handle(\$readfh);
                }
            }
        },
        read_error => sub {
            my (\$t, \$fh) = \@_;
            if (\$fh == \$readfh) {
                print "pipe error (exception)!\\n";
                \$t->remove_input_handle(\$readfh);
            }
        },
        munge_output => sub {
            my (\$t, \$buf) = \@_;
            syswrite(\$writefh, "read from term: \$buf");
            \$buf;
        },
    }
);
\$term->run(\$^X, '-ple', q[last if /^\$/]);
print "done\\n";
SCRIPT

my $crlf = "\x0d\x0a";

# just in case
alarm 60;

{
    my $pty = IO::Pty::Easy->new(handle_pty_size => 0);
    $pty->spawn($^X, (map { "-I $_" } @INC), '-e', $script);

    open my $readfh, '>', $readp
        or die "can't open pipe (parent): $!";
    open my $writefh, '<', $writep
        or die "can't open pipe (parent): $!";

    $pty->write("foo\n");

    is($pty->read(undef, 5), "foo$crlf");
    is($pty->read(undef, 5), "foo$crlf");

    {
        my $buf;
        sysread($writefh, $buf, 21);
        is($buf, "read from term: foo$crlf");
        sysread($writefh, $buf, 21);
        is($buf, "read from term: foo$crlf");
    }

    syswrite($readfh, "bar");

    is($pty->read(undef, 21), "read from pipe: bar\n");

    close($readfh);
    close($writefh);

    is($pty->read(undef, 19), "pipe error (read)!\n");
}

done_testing;
