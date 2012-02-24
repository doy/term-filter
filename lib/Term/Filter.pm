package Term::Filter;
use Moose;

use IO::Pty::Easy;
use Scope::Guard;
use Term::ReadKey;

has callbacks => (
    is      => 'ro',
    isa     => 'HashRef[CodeRef]',
    default => sub { {} },
);

sub _callback {
    my $self = shift;
    my ($event) = @_;
    my $callback = $self->callbacks->{$event};
    return unless $callback;
    return $callback->(@_);
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
    isa     => 'FileHandle',
    lazy    => 1,
    builder => '_build_input',
);

sub _build_input { \*STDIN }

has output => (
    is      => 'ro',
    isa     => 'FileHandle',
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
        input_handles => 'elements',
    },
);

sub _build_input_handles {
    my $self = shift;
    [ $self->input, $self->pty ]
}

sub _build_input_select_vec {
    my $self = shift;

    my $vec = '';
    for my $handle ($self->input_handles) {
        vec($vec, fileno($handle), 1) = 1;
    }

    return $vec;
}

has _got_winch => (
    is       => 'rw',
    isa      => 'Bool',
    default  => 0,
    init_arg => undef,
);

has _raw_mode => (
    is       => 'rw',
    isa      => 'Bool',
    default  => 0,
    init_arg => undef,
    trigger  => sub {
        my $self = shift;
        my ($val) = @_;
        if ($val) {
            ReadMode 5;
        }
        else {
            ReadMode 0;
        }
    },
);

sub read_from_handle {
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

sub write_to_handle {
    my $self = shift;
    my ($handle, $buf) = @_;

    # XXX should i select here? or buffer?
    syswrite $handle, $buf;
}

sub run {
    my $self = shift;
    my @cmd = @_;

    my $guard = $self->_setup(@cmd);

    while (1) {
        my ($rout, $eout) = $self->_retry_select;

        $self->_callback('error', $eout);

        if (vec($rout, fileno($self->input), 1)) {
            my $got = $self->read_from_handle($self->input, "STDIN");
            last unless defined $got;
            $got = $self->_callback('munge_input', $got)
                if $self->_has_callback('munge_input');
            $self->write_to_handle($self->pty, $got);
        }

        if (vec($rout, fileno($self->pty), 1)) {
            my $got = $self->read_from_handle($self->pty, "pty");
            last unless defined $got;
            $got = $self->_callback('munge_output', $got)
                if $self->_has_callback('munge_output');
            $self->write_to_handle($self->output, $got);
        }

        $self->_callback('read', $rout);
    }
}

sub _setup {
    my $self = shift;
    my (@cmd) = @_;

    $self->pty->spawn(@cmd) || die "Couldn't spawn @cmd: $!";

    $self->_raw_mode(1);

    my $prev_winch = $SIG{WINCH};
    $SIG{WINCH} = sub {
        $self->_got_winch(1);
        $self->pty->slave->clone_winsize_from(\*STDIN);

        $self->pty->kill('WINCH', 1);

        $self->_callback('winch');

        $prev_winch->();
    };

    my $undo = $self->_callback('setup', @cmd);

    return Scope::Guard->new(sub {
        $SIG{WINCH} = $prev_winch;
        $self->_raw_mode(0);
        $undo->() if $undo;
    });
}

sub _retry_select {
    my $self = shift;

    my ($rout, $eout);
    my ($rin, $ein) = ($self->_build_input_select_vec) x 2;
    my $res = select($rout = $rin, undef, $eout = $ein, undef);
    my $again = $!{EAGAIN} || $!{EINTR};

    if (($res == -1 && $again) || $self->_got_winch) {
        $self->_got_winch(0);
        return $self->_retry_select;
    }

    return ($rout, $eout);
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
