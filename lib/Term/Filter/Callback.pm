package Term::Filter::Callback;
use Moose;
# ABSTRACT: Simple callback-based wrapper for L<Term::Filter>

with 'Term::Filter';

=head1 SYNOPSIS

  use Term::Filter::Callback;

  my $term = Term::Filter::Callback->new(
      callbacks => {
          munge_input => sub {
              my $self = shift;
              my ($got) = @_;
              $got =~ s/\ce/E-  Elbereth\n/g;
              $got;
          },
          munge_output => sub {
              my $self = shift;
              my ($got) = @_;
              $got =~ s/(Elbereth)/\e[35m$1\e[m/g;
              $got;
          },
      },
  );

  $term->run('nethack');

=head1 DESCRIPTION

This module provides a callback-based API to L<Term::Filter>. The desired
callbacks can just be passed into the constructor of this class, rather than
requiring a new class to be manually defined. This class consumes the
L<Term::Filter> role, so the rest of the documentation in that module applies
here.

=cut

=attr callbacks

A hashref of callbacks for L<Term::Filter>. The keys are
L<callback names|Term::Filter/CALLBACKS> and the values are coderefs to call
for those callbacks.

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
