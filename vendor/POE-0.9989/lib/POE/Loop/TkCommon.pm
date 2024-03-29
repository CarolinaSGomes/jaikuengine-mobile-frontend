# $Id: TkCommon.pm 2163 2007-01-03 06:13:16Z rcaputo $

# The common bits of our system-specific Tk event loops.  This is
# everything but file handling.

# Empty package to appease perl.
package POE::Loop::TkCommon;

# Include common signal handling.
use POE::Loop::PerlSignals;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision: 2163 $=~/(\d+)/);sprintf"1.%04d",$r};

use Tk 800.021;
use 5.00503;

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

use Tk qw(DoOneEvent DONT_WAIT ALL_EVENTS);

my $_watcher_time;
my $_waiting_for_event = 0;

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_attach_uidestroy {
  my ($self, $window) = @_;

  $window->OnDestroy(
    sub {
      if ($self->_data_ses_count()) {

        $self->_dispatch_event(
          $self, $self,
          EN_SIGNAL, ET_SIGNAL, [ 'UIDESTROY' ],
          __FILE__, __LINE__, time(), -__LINE__
        );

        # Flag the main loop as done.
        $_waiting_for_event = 0;
      }
    }
  );
}

#------------------------------------------------------------------------------
# Maintain time watchers.

sub loop_resume_time_watcher {
  my ($self, $next_time) = @_;
  $self->loop_pause_time_watcher();
  my $timeout = $next_time - time();

  return if $timeout < 0;
  $_waiting_for_event = 1;
  $_watcher_time = $poe_main_window->after(
    $timeout * 1000, [ sub { $_waiting_for_event = 0 } ]
  );
}

sub loop_reset_time_watcher {
  my ($self, $next_time) = @_;
  $self->loop_resume_time_watcher($next_time);
}

sub loop_pause_time_watcher {
  my $self = shift;
  if (defined $_watcher_time) {
    $_watcher_time->cancel() if $_watcher_time->can("cancel");
    $_watcher_time = undef;
  }
  $_waiting_for_event = 0;
}

# TODO - Ton Hospel's Tk event loop doesn't mix alarms and immediate
# events.  Rather, it keeps a list of immediate events and defers
# queuing of alarms to something else.
#
#  sub loop {
#      # Extra test without alarm handling makes alarm priority normal
#      (@immediate && run_signals),
#      DoOneEvent(DONT_WAIT | FILE_EVENTS | WINDOW_EVENTS) while 
#          (@immediate && run_signals), !@loops && DoOneEvent;
#      return shift @loops;
#  }
#
# The immediate events are dispatched in a chunk between calls to Tk's
# event loop.  He uses a double buffer: As events are processed in
# @immediate, new ones go into a different list.  Once @immediate is
# exhausted, the second list is copied in.
#
# The double buffered queue means that @immediate is alternately
# exhausted and filled.  It's impossible to fill @immediate while it's
# being processed, so sub handle_foo { yield("foo") } won't run
# forever.
#
# This has a side effect of deferring any alarms until after
# @immediate is exhausted.  I suspect the semantics are similar to
# POE's queue anyway, however.

#------------------------------------------------------------------------------
# Tk traps errors in an effort to survive them.  However, since POE
# does not, this leaves us in a strange, inconsistent state.  Here we
# re-trap the errors and rethrow them as UIDESTROY.

sub Tk::Error {
  my $window = shift;
  my $error  = shift;

  if (Tk::Exists($window)) {
    my $grab = $window->grab('current');
    $grab->Unbusy if defined $grab;
  }
  chomp($error);
  POE::Kernel::_warn "Tk::Error: $error\n " . join("\n ",@_)."\n";

  if ($poe_kernel->_data_ses_count()) {
    $poe_kernel->_dispatch_event(
      $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL, [ 'UIDESTROY' ],
      __FILE__, __LINE__, time(), -__LINE__
    );
  }
}

#------------------------------------------------------------------------------
# The event loop itself.

sub loop_do_timeslice {
  my $self = shift;

  # Check for a hung kernel.
  $self->_test_if_kernel_is_idle();
  my $now;
  $now = time() if TRACE_STATISTICS;

  # Idle until the next POE event is due.  Process at least one event
  # to update the waiting flag, then block until a POE event is ready.
  DoOneEvent(DONT_WAIT | ALL_EVENTS);
  while ($_waiting_for_event) {
    DoOneEvent(ALL_EVENTS);
  }

  $self->_data_stat_add('idle_seconds', time() - $now) if TRACE_STATISTICS;

  # Dispatch whatever events are due.  Update the next dispatch time.
  $self->_data_ev_dispatch_due();
}

sub loop_run {
  my $self = shift;

  # Run for as long as there are sessions to service.
  while ($self->_data_ses_count()) {
    $self->loop_do_timeslice();
  }
}

sub loop_halt {
  # Do nothing.
}

1;

__END__

=head1 NAME

POE::Loop::TkCommon - common features of POE's Tk event loop bridges

=head1 SYNOPSIS

See L<POE::Loop>.

=head1 DESCRIPTION

This class is an implementation of the abstract POE::Loop interface.
It follows POE::Loop's public interface exactly.  Therefore, please
see L<POE::Loop> for its documentation.

=head1 SEE ALSO

L<POE>, L<POE::Loop>, L<Tk>

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about authors, contributors,
and POE's licensing.

=cut
