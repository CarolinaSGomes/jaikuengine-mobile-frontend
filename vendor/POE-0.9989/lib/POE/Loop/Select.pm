# $Id: Select.pm 1980 2006-06-11 19:23:12Z rcaputo $

# Select loop bridge for POE::Kernel.

# Empty package to appease perl.
package POE::Loop::Select;

use strict;

# Include common signal handling.
use POE::Loop::PerlSignals;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision: 1980 $=~/(\d+)/);sprintf"1.%04d",$r};

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;
use Errno qw(EINPROGRESS EWOULDBLOCK EINTR);

# select() vectors.  They're stored in an array so that the MODE_*
# offsets can refer to them.  This saves some code at the expense of
# clock cycles.
#
# [ $select_read_bit_vector,    (MODE_RD)
#   $select_write_bit_vector,   (MODE_WR)
#   $select_expedite_bit_vector (MODE_EX)
# ];
my @loop_vectors = ("", "", "");

# A record of the file descriptors we are actively watching.
my %loop_filenos;

# Allow $^T to change without affecting our internals.
my $start_time = $^T;

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $self = shift;

  # Initialize the vectors as vectors.
  @loop_vectors = ( '', '', '' );
  vec($loop_vectors[MODE_RD], 0, 1) = 0;
  vec($loop_vectors[MODE_WR], 0, 1) = 0;
  vec($loop_vectors[MODE_EX], 0, 1) = 0;
}

sub loop_finalize {
  my $self = shift;

  # This is "clever" in that it relies on each symbol on the left to
  # be stringified by the => operator.
  my %kernel_modes = (
    MODE_RD => MODE_RD,
    MODE_WR => MODE_WR,
    MODE_EX => MODE_EX,
  );

  while (my ($mode_name, $mode_offset) = each(%kernel_modes)) {
    my $bits = unpack('b*', $loop_vectors[$mode_offset]);
    if (index($bits, '1') >= 0) {
      POE::Kernel::_warn "<rc> LOOP VECTOR LEAK: $mode_name = $bits\a\n";
    }
  }

  $self->loop_ignore_all_signals();
}

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_attach_uidestroy {
  # does nothing
}

#------------------------------------------------------------------------------
# Maintain time watchers.

sub loop_resume_time_watcher {
  # does nothing ($_[0] == next time)
}

sub loop_reset_time_watcher {
  # does nothing ($_[0] == next time)
}

sub loop_pause_time_watcher {
  # does nothing
}

#------------------------------------------------------------------------------
# Maintain filehandle watchers.

sub loop_watch_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$mode], $fileno, 1) = 1;
  $loop_filenos{$fileno} |= (1<<$mode);
}

sub loop_ignore_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$mode], $fileno, 1) = 0;
  $loop_filenos{$fileno} &= ~(1<<$mode);
}

sub loop_pause_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$mode], $fileno, 1) = 0;
  $loop_filenos{$fileno} &= ~(1<<$mode);
}

sub loop_resume_filehandle {
  my ($self, $handle, $mode) = @_;
  my $fileno = fileno($handle);

  vec($loop_vectors[$mode], $fileno, 1) = 1;
  $loop_filenos{$fileno} |= (1<<$mode);
}

#------------------------------------------------------------------------------
# The event loop itself.

sub loop_do_timeslice {
  my $self = shift;

  # Check for a hung kernel.
  $self->_test_if_kernel_is_idle();

  # Determine which files are being watched.  This is a heavy
  # operation; significant time will pass during it, so we do it
  # before deciding on the timeout.
  my @filenos = ();
  while (my ($fd, $mask) = each(%loop_filenos)) {
    push(@filenos, $fd) if $mask;
  }

  # Set the select timeout based on current queue conditions.  If
  # there are FIFO events, then the timeout is zero to poll select and
  # move on.  Otherwise set the select timeout until the next pending
  # event, if there are any.  If nothing is waiting, set the timeout
  # for some constant number of seconds.

  my $timeout = $self->get_next_event_time();

  my $now = time();
  if (defined $timeout) {
    $timeout -= $now;
    $timeout = 0 if $timeout < 0;
  }
  else {
    $timeout = 3600;
  }

  # Tracing is relatively expensive, but it's not for live systems.
  # We can get away with it being after the timeout calculation.
  if (TRACE_EVENTS) {
    POE::Kernel::_warn(
      '<ev> Kernel::run() iterating.  ' .
      sprintf(
        "now(%.4f) timeout(%.4f) then(%.4f)\n",
        $now - $start_time, $timeout, ($now - $start_time) + $timeout
      )
    );
  }

  if (TRACE_FILES) {
    POE::Kernel::_warn(
      "<fh> ,----- SELECT BITS IN -----\n",
      "<fh> | READ    : ", unpack('b*', $loop_vectors[MODE_RD]), "\n",
      "<fh> | WRITE   : ", unpack('b*', $loop_vectors[MODE_WR]), "\n",
      "<fh> | EXPEDITE: ", unpack('b*', $loop_vectors[MODE_EX]), "\n",
      "<fh> `--------------------------\n"
    );
  }

  # Avoid looking at filehandles if we don't need to.  -><- The added
  # code to make this sleep is non-optimal.  There is a way to do this
  # in fewer tests.

  if ($timeout or @filenos) {

    # There are filehandles to poll, so do so.

    if (@filenos) {
      # Check filehandles, or wait for a period of time to elapse.
      my $hits = CORE::select(
        my $rout = $loop_vectors[MODE_RD],
        my $wout = $loop_vectors[MODE_WR],
        my $eout = $loop_vectors[MODE_EX],
        $timeout,
      );

      if (ASSERT_FILES) {
        if (
          $hits < 0 and
          $! != EINPROGRESS and
          $! != EWOULDBLOCK and
          $! != EINTR
        ) {
          POE::Kernel::_trap("<fh> select error: $!");
        }
      }

      if (TRACE_FILES) {
        if ($hits > 0) {
          POE::Kernel::_warn "<fh> select hits = $hits\n";
        }
        elsif ($hits == 0) {
          POE::Kernel::_warn "<fh> select timed out...\n";
        }
        POE::Kernel::_warn(
          "<fh> ,----- SELECT BITS OUT -----\n",
          "<fh> | READ    : ", unpack('b*', $rout), "\n",
          "<fh> | WRITE   : ", unpack('b*', $wout), "\n",
          "<fh> | EXPEDITE: ", unpack('b*', $eout), "\n",
          "<fh> `---------------------------\n"
        );
      }

      # If select has seen filehandle activity, then gather up the
      # active filehandles and synchronously dispatch events to the
      # appropriate handlers.

      if ($hits > 0) {

        # This is where they're gathered.  It's a variant on a neat
        # hack Silmaril came up with.

        my (@rd_selects, @wr_selects, @ex_selects);
        foreach (@filenos) {
          push(@rd_selects, $_) if vec($rout, $_, 1);
          push(@wr_selects, $_) if vec($wout, $_, 1);
          push(@ex_selects, $_) if vec($eout, $_, 1);
        }

        if (TRACE_FILES) {
          if (@rd_selects) {
            POE::Kernel::_warn(
              "<fh> found pending rd selects: ",
              join( ', ', sort { $a <=> $b } @rd_selects ),
              "\n"
            );
          }
          if (@wr_selects) {
            POE::Kernel::_warn(
              "<sl> found pending wr selects: ",
              join( ', ', sort { $a <=> $b } @wr_selects ),
              "\n"
            );
          }
          if (@ex_selects) {
            POE::Kernel::_warn(
              "<sl> found pending ex selects: ",
              join( ', ', sort { $a <=> $b } @ex_selects ),
              "\n"
            );
          }
        }

        if (ASSERT_FILES) {
          unless (@rd_selects or @wr_selects or @ex_selects) {
            POE::Kernel::_trap(
              "<fh> found no selects, with $hits hits from select???\n"
            );
          }
        }

        # Enqueue the gathered selects, and flag them as temporarily
        # paused.  They'll resume after dispatch.

        @rd_selects and
          $self->_data_handle_enqueue_ready(MODE_RD, @rd_selects);
        @wr_selects and
          $self->_data_handle_enqueue_ready(MODE_WR, @wr_selects);
        @ex_selects and
          $self->_data_handle_enqueue_ready(MODE_EX, @ex_selects);
      }
    }

    # No filehandles to select on.  Four-argument select() fails on
    # MSWin32 with all undef bitmasks.  Use sleep() there instead.

    else {
      # Not unconditionally the Time::HiRes microsleep because
      # Time::HiRes may not be installed.  This is only an issue until
      # we can require versions of Perl that include Time::HiRes.
      if ($^O eq 'MSWin32') {
        sleep($timeout);
      }
      else {
        CORE::select(undef, undef, undef, $timeout);
      }
    }
  }

  if (TRACE_STATISTICS) {
    # TODO - I think $now is too far ahead of select() and this call
    # is too far afterwards.  Unless "idle" seconds means also the
    # time POE::Kernel spends scheduling things.  Sent a note to Nick
    # Williams asking for clarification on the definitions of various
    # statistics.
    $self->_data_stat_add('idle_seconds', time() - $now);
  }

  # Dispatch whatever events are due.
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
  # does nothing
}

1;

__END__

=head1 NAME

POE::Loop::Select - a bridge that supports select(2) from POE

=head1 SYNOPSIS

See L<POE::Loop>.

=head1 DESCRIPTION

This class is an implementation of the abstract POE::Loop interface.
It follows POE::Loop's public interface exactly.  Therefore, please
see L<POE::Loop> for its documentation.

=head1 SEE ALSO

L<POE>, L<POE::Loop>, L<select>

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about authors, contributors,
and POE's licensing.

=cut
