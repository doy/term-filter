package Term::Filter;
use Moose::Role;
# ABSTRACT: Run an interactive terminal session, filtering the input and output

use IO::Pty::Easy ();
use IO::Select ();
use Moose::Util::TypeConstraints 'subtype', 'as', 'where', 'message';
use Scope::Guard ();
use Term::ReadKey ();

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

subtype     'Term::Filter::TtyFileHandle',
    as      'FileHandle',
    where   { -t $_ },
    message { "Term::Filter requires input and output filehandles to be attached to a terminal" };

=attr input

=cut

has input => (
    is      => 'ro',
    isa     => 'Term::Filter::TtyFileHandle',
    lazy    => 1,
    builder => '_build_input',
);

sub _build_input { \*STDIN }

=attr output

=cut

has output => (
    is      => 'ro',
    isa     => 'Term::Filter::TtyFileHandle',
    lazy    => 1,
    builder => '_build_output',
);

sub _build_output { \*STDOUT }

=attr input_handles

=cut

=method add_input_handle

=cut

=method remove_input_handle

=cut

has input_handles => (
    traits   => ['Array'],
    isa      => 'ArrayRef[FileHandle]',
    lazy     => 1,
    init_arg => undef,
    builder  => '_build_input_handles',
    writer   => '_set_input_handles',
    handles  => {
        input_handles       => 'elements',
        add_input_handle    => 'push',
        _grep_input_handles => 'grep',
    },
);

sub _build_input_handles {
    my $self = shift;
    [ $self->input, $self->pty ]
}

sub remove_input_handle {
    my $self = shift;
    my ($fh) = @_;
    $self->_set_input_handles(
        [ $self->_grep_input_handles(sub { $_ != $fh }) ]
    );
    $self->_clear_select;
}

=attr pty

=cut

has pty => (
    is      => 'ro',
    isa     => 'IO::Pty::Easy',
    lazy    => 1,
    builder => '_build_pty',
);

sub _build_pty { IO::Pty::Easy->new(raw => 0) }

has _select => (
    is      => 'ro',
    isa     => 'IO::Select',
    lazy    => 1,
    builder => '_build_select',
    clearer => '_clear_select',
);

sub _build_select {
    my $self = shift;
    return IO::Select->new($self->input_handles);
}

has _raw_mode => (
    is       => 'rw',
    isa      => 'Bool',
    default  => 0,
    init_arg => undef,
    trigger  => sub {
        my $self = shift;
        my ($val) = @_;
        if ($val) {
            Term::ReadKey::ReadMode(5, $self->input);
        }
        else {
            Term::ReadKey::ReadMode(0, $self->input);
        }
    },
);

=method run

=cut

sub run {
    my $self = shift;
    my @cmd = @_;

    my $guard = $self->_setup(@cmd);

    LOOP: while (1) {
        my ($r, undef, $e) = IO::Select->select(
            $self->_select, undef, $self->_select,
        );

        for my $fh (@$e) {
            $self->read_error($fh);
        }

        for my $fh (@$r) {
            if ($fh == $self->input) {
                my $got = $self->_read_from_handle($self->input, "STDIN");
                last LOOP unless defined $got;

                $got = $self->munge_input($got);

                # XXX should i select here, or buffer, to make sure this
                # doesn't block?
                syswrite $self->pty, $got;
            }
            elsif ($fh == $self->pty) {
                my $got = $self->_read_from_handle($self->pty, "pty");
                last LOOP unless defined $got;

                $got = $self->munge_output($got);

                # XXX should i select here, or buffer, to make sure this
                # doesn't block?
                syswrite $self->output, $got;
            }
            else {
                $self->read($fh);
            }
        }
    }
}

sub _setup {
    my $self = shift;
    my (@cmd) = @_;

    Carp::croak("Must be run attached to a tty")
        unless -t $self->input && -t $self->output;

    $self->pty->spawn(@cmd) || Carp::croak("Couldn't spawn @cmd: $!");

    $self->_raw_mode(1);

    my $prev_winch = $SIG{WINCH};
    $SIG{WINCH} = sub {
        $self->pty->slave->clone_winsize_from($self->input);

        $self->pty->kill('WINCH', 1);

        $self->winch;

        $prev_winch->();
    };

    my $setup_called;
    my $guard = Scope::Guard->new(sub {
        $SIG{WINCH} = $prev_winch;
        $self->_raw_mode(0);
        $self->cleanup if $setup_called;
    });

    $self->setup(@cmd);
    $setup_called = 1;

    return $guard;
}

sub _read_from_handle {
    my $self = shift;
    my ($handle, $name) = @_;

    my $buf;
    sysread $handle, $buf, 4096;
    if (!defined $buf || length $buf == 0) {
        Carp::croak("Error reading from $name: $!")
            unless defined $buf;
        return;
    }

    return $buf;
}

sub setup        { }
sub cleanup      { }
sub munge_input  { $_[1] }
sub munge_output { $_[1] }
sub read         { }
sub read_error   { }
sub winch        { }

no Moose::Role;
no Moose::Util::TypeConstraints;

=head1 BUGS

No known bugs.

Please report any bugs through RT: email
C<bug-term-filter at rt.cpan.org>, or browse to
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Term-Filter>.

=head1 SEE ALSO

L<http://termcast.org/>

=head1 SUPPORT

You can find this documentation for this module with the perldoc command.

    perldoc Term::Filter

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Term-Filter>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Term-Filter>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Term-Filter>

=item * Search CPAN

L<http://search.cpan.org/dist/Term-Filter>

=back

=cut

1;
