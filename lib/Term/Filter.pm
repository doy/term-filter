package Term::Filter;
use Moose;
# ABSTRACT: Run an interactive terminal session, filtering the input and output

use IO::Pty::Easy ();
use IO::Select ();
use Moose::Util::TypeConstraints 'subtype', 'as', 'where', 'message';
use Scope::Guard ();
use Term::ReadKey ();

subtype     'Term::Filter::TtyFileHandle',
    as      'FileHandle',
    where   { -t $_ },
    message { "Term::Filter requires input and output filehandles to be attached to a terminal" };

has callbacks => (
    is      => 'ro',
    isa     => 'HashRef[CodeRef]',
    default => sub { {} },
);

sub _callback {
    my $self = shift;
    my ($event, @args) = @_;
    my $callback = $self->callbacks->{$event};
    return unless $callback;
    return $self->$callback(@args);
}

sub _has_callback {
    my $self = shift;
    my ($event) = @_;
    return exists $self->callbacks->{$event};
}

has pty => (
    is      => 'ro',
    isa     => 'IO::Pty::Easy',
    lazy    => 1,
    builder => '_build_pty',
);

sub _build_pty { IO::Pty::Easy->new(raw => 0) }

has input => (
    is      => 'ro',
    isa     => 'Term::Filter::TtyFileHandle',
    lazy    => 1,
    builder => '_build_input',
);

sub _build_input { \*STDIN }

has output => (
    is      => 'ro',
    isa     => 'Term::Filter::TtyFileHandle',
    lazy    => 1,
    builder => '_build_output',
);

sub _build_output { \*STDOUT }

has input_handles => (
    traits   => ['Array'],
    isa      => 'ArrayRef[FileHandle]',
    lazy     => 1,
    init_arg => undef,
    builder  => '_build_input_handles',
    handles  => {
        input_handles    => 'elements',
        add_input_handle => 'push',
    },
);

sub _build_input_handles {
    my $self = shift;
    [ $self->input, $self->pty ]
}

has select => (
    is  => 'ro',
    isa => 'IO::Select',
    lazy => 1,
    builder => '_build_select',
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
            Term::ReadKey::ReadMode 5;
        }
        else {
            Term::ReadKey::ReadMode 0;
        }
    },
);

sub run {
    my $self = shift;
    my @cmd = @_;

    my $guard = $self->_setup(@cmd);

    LOOP: while (1) {
        my ($r, undef, $e) = IO::Select->select(
            $self->select, undef, $self->select,
        );

        for my $fh (@$e) {
            $self->_callback('read_error', $fh);
        }

        for my $fh (@$r) {
            if ($fh == $self->input) {
                my $got = $self->_read_from_handle($self->input, "STDIN");
                last LOOP unless defined $got;

                $got = $self->_callback('munge_input', $got)
                    if $self->_has_callback('munge_input');

                # XXX should i select here, or buffer, to make sure this
                # doesn't block?
                syswrite $self->pty, $got;
            }
            elsif ($fh == $self->pty) {
                my $got = $self->_read_from_handle($self->pty, "pty");
                last LOOP unless defined $got;

                $got = $self->_callback('munge_output', $got)
                    if $self->_has_callback('munge_output');

                # XXX should i select here, or buffer, to make sure this
                # doesn't block?
                syswrite $self->output, $got;
            }
            else {
                $self->_callback('read', $fh);
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

        $self->_callback('winch');

        $prev_winch->();
    };

    my $setup_called;
    my $guard = Scope::Guard->new(sub {
        $SIG{WINCH} = $prev_winch;
        $self->_raw_mode(0);
        $self->_callback('cleanup') if $setup_called;
    });

    $self->_callback('setup', @cmd);
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

__PACKAGE__->meta->make_immutable;
no Moose;
no Moose::Util::TypeConstraints;

1;
