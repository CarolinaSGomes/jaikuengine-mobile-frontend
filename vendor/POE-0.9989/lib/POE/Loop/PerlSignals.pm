# $Id: PerlSignals.pm 1980 2006-06-11 19:23:12Z rcaputo $

# Plain Perl signal handling is something shared by several event
# loops.  The invariant code has moved out here so that each loop may
# use it without reinventing it.  This will save maintenance and
# shrink the distribution.  Yay!

package POE::Loop::PerlSignals;

use strict;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision: 1980 $=~/(\d+)/);sprintf"1.%04d",$r};

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;
use POE::Kernel;

# Flag so we know which signals are watched.  Used to reset those
# signals during finalization.
my %signal_watched;

#------------------------------------------------------------------------------
# Signal handlers/callbacks.

sub _loop_signal_handler_generic {
  if (TRACE_SIGNALS) {
    POE::Kernel::_warn "<sg> Enqueuing generic SIG$_[0] event";
  }

  $poe_kernel->_data_ev_enqueue(
    $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0] ],
    __FILE__, __LINE__, undef, time()
  );
  $SIG{$_[0]} = \&_loop_signal_handler_generic;
}

sub _loop_signal_handler_pipe {
  if (TRACE_SIGNALS) {
    POE::Kernel::_warn "<sg> Enqueuing PIPE-like SIG$_[0] event";
  }

  $poe_kernel->_data_ev_enqueue(
    $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[0] ],
    __FILE__, __LINE__, undef, time()
  );
  $SIG{$_[0]} = \&_loop_signal_handler_pipe;
}

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_watch_signal {
  my ($self, $signal) = @_;

  $signal_watched{$signal} = 1;

  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {
# We should never twiddle $SIG{CH?LD} under poe, unless we want to override
# system() and friends. --hachi
#    $SIG{$signal} = "DEFAULT";
    $self->_data_sig_begin_polling();
    return;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    $SIG{$signal} = \&_loop_signal_handler_pipe;
    return;
  }

  # Everything else.
  $SIG{$signal} = \&_loop_signal_handler_generic;
}

sub loop_ignore_signal {
  my ($self, $signal) = @_;

  delete $signal_watched{$signal};

  if ($signal eq 'CHLD' or $signal eq 'CLD') {
    $self->_data_sig_cease_polling();
# We should never twiddle $SIG{CH?LD} under poe, unless we want to override
# system() and friends. --hachi
#    $SIG{$signal} = "IGNORE";
    return;
  }

  if ($signal eq 'PIPE') {
    $SIG{$signal} = "IGNORE";
    return;
  }

  $SIG{$signal} = "DEFAULT";
}

sub loop_ignore_all_signals {
  my $self = shift;
  foreach my $signal (keys %signal_watched) {
    $self->loop_ignore_signal($signal);
  }
}

1;

__END__

=head1 NAME

POE::Loop::PerlSignals - plain Perl signal handlers used by many loops

=head1 SYNOPSIS

See L<POE::Loop>.

=head1 DESCRIPTION

This class is an implementation of the signal handling functions
defined by the abstract POE::Loop interface.  It follows POE::Loop's
public interface for signal handling exactly.  Therefore, please see
L<POE::Loop> for its documentation.

=head1 SEE ALSO

L<POE>, L<POE::Loop>

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about authors, contributors,
and POE's licensing.

=cut
