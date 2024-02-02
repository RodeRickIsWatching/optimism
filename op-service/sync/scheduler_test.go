package sync

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestScheduler(t *testing.T) {
	t.Run("ImmediateShutdown", func(t *testing.T) {
		runner := func(ctx context.Context, item int) {}
		s := NewSchedulerFromBufferSize(runner, 1)
		s.Start(context.Background())
		err := s.Close()
		require.NoError(t, err)
	})

	t.Run("ScheduleMessage", func(t *testing.T) {
		runnerCalls := 0
		runner := func(ctx context.Context, item int) {
			runnerCalls++
		}
		s := NewSchedulerFromBufferSize(runner, 1)
		s.Start(context.Background())
		err := s.Schedule(1)
		require.NoError(t, err)
		require.Eventually(t, func() bool {
			return runnerCalls > 0
		}, 10*time.Second, 10*time.Millisecond)
	})

	t.Run("ScheduleMessageBufferFull", func(t *testing.T) {
		runnerCalls := 0
		runner := func(ctx context.Context, item int) {
			runnerCalls++
		}
		s := NewSchedulerFromBufferSize(runner, 1)
		s.Start(context.Background())
		err := s.Schedule(1)
		require.NoError(t, err)
		err = s.Schedule(2)
		require.Error(t, err)
		require.Eventually(t, func() bool {
			return runnerCalls > 0
		}, 10*time.Second, 10*time.Millisecond)
	})
}
