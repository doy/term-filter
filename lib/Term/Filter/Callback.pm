package Term::Filter::Callback;
use Moose;
# ABSTRACT: Simple callback-based wrapper for L<Term::Filter>

with 'Term::Filter';

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

=attr callbacks

=cut

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

for my $method (qw(setup cleanup munge_input munge_output
                   read read_error winch)) {
    __PACKAGE__->meta->add_around_method_modifier(
        $method => sub {
            my $orig = shift;
            my $self = shift;
            if ($self->_has_callback($method)) {
                return $self->_callback($method, @_);
            }
            else {
                return $self->$orig(@_);
            }
        },
    );
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
