package handlers

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/api/internal/db"
	"github.com/e2b-dev/infra/packages/api/internal/orchestrator"
	"github.com/e2b-dev/infra/packages/api/internal/sandbox"
	"github.com/e2b-dev/infra/packages/api/internal/utils"
	"github.com/e2b-dev/infra/packages/auth/pkg/auth"
	"github.com/e2b-dev/infra/packages/db/queries"
	"github.com/e2b-dev/infra/packages/shared/pkg/clusters"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

func (a *APIStore) deleteSnapshot(ctx context.Context, sandboxID string, teamID, clusterID uuid.UUID) error {
	snapshot, err := a.throttledGetSnapshotBuilds(ctx, teamID, sandboxID)
	if err != nil {
		return err
	}

	aliasKeys, dbErr := a.sqlcDB.DeleteTemplate(ctx, queries.DeleteTemplateParams{
		TeamID:     teamID,
		TemplateID: snapshot.TemplateID,
	})
	if dbErr != nil {
		return fmt.Errorf("error deleting template from db: %w", dbErr)
	}

	a.templateCache.InvalidateAllTags(context.WithoutCancel(ctx), snapshot.TemplateID)
	a.templateCache.InvalidateAliasesByTemplateID(context.WithoutCancel(ctx), snapshot.TemplateID, aliasKeys)
	a.snapshotCache.Invalidate(context.WithoutCancel(ctx), sandboxID)

	// Delete the snapshot blobs in object storage for every build of this
	// snapshot. The DB delete + cache invalidation above is not sufficient:
	// without this loop the fc-templates bucket keeps the actual memfile +
	// rootfs files indefinitely, growing monotonically with kill volume.
	// Best-effort — failures are logged but don't fail the kill, and the
	// bucket-level lifecycle rule (iac/provider-aws/init/buckets.tf) sweeps
	// any leftovers as a backstop.
	for _, build := range snapshot.Builds {
		buildErr := a.templateManager.DeleteBuild(
			context.WithoutCancel(ctx),
			build.BuildID,
			snapshot.TemplateID,
			clusterID,
			build.ClusterNodeID,
		)
		if buildErr != nil {
			logger.L().Warn(ctx, "failed to delete snapshot blobs from object storage",
				zap.Error(buildErr),
				logger.WithSandboxID(sandboxID),
				logger.WithBuildID(build.BuildID.String()),
				logger.WithTemplateID(snapshot.TemplateID),
				logger.WithClusterID(clusterID),
			)
		}
	}

	return nil
}

func (a *APIStore) DeleteSandboxesSandboxID(
	c *gin.Context,
	sandboxID string,
) {
	ctx := c.Request.Context()

	var err error
	sandboxID, err = utils.ShortID(sandboxID)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusBadRequest, "Invalid sandbox ID")

		return
	}

	team := auth.MustGetTeamInfo(c)
	teamID := team.ID
	clusterID := clusters.WithClusterFallback(team.ClusterID)

	telemetry.SetAttributes(ctx,
		telemetry.WithSandboxID(sandboxID),
		telemetry.WithTeamID(teamID.String()),
	)

	telemetry.ReportEvent(ctx, "killing sandbox")

	killedOrRemoved := false

	err = a.orchestrator.RemoveSandbox(ctx, teamID, sandboxID, sandbox.RemoveOpts{Action: sandbox.StateActionKill})
	switch {
	case err == nil:
		killedOrRemoved = true
	case errors.Is(err, orchestrator.ErrSandboxNotFound):
		logger.L().Debug(ctx, "Running sandbox not found", logger.WithSandboxID(sandboxID))
	case errors.Is(err, orchestrator.ErrSandboxOperationFailed):
		a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error killing sandbox: %s", err))

		return
	default:
		telemetry.ReportError(ctx, "error killing sandbox", err)
		a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error killing sandbox: %s", err))

		return
	}

	// remove any snapshots when the sandbox is not running
	deleteSnapshotErr := a.deleteSnapshot(ctx, sandboxID, teamID, clusterID)
	switch {
	case errors.Is(deleteSnapshotErr, db.ErrSnapshotNotFound):
		// no snapshot found, nothing to do
	case deleteSnapshotErr != nil:
		telemetry.ReportError(ctx, "error deleting sandbox", deleteSnapshotErr)
		a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error deleting sandbox: %s", deleteSnapshotErr))

		return
	default:
		killedOrRemoved = true
	}

	if killedOrRemoved {
		c.Status(http.StatusNoContent)
	} else {
		logger.L().Debug(ctx, "Sandbox not found for deletion", logger.WithSandboxID(sandboxID))
		a.sendAPIStoreError(c, http.StatusNotFound, utils.SandboxNotFoundMsg(sandboxID))
	}
}

// throttledGetSnapshotBuilds runs GetSnapshotBuilds gated by the snapshot build query semaphore.
func (a *APIStore) throttledGetSnapshotBuilds(ctx context.Context, teamID uuid.UUID, sandboxID string) (db.SnapshotBuilds, error) {
	if err := a.snapshotBuildQuerySem.Acquire(ctx, 1); err != nil {
		return db.SnapshotBuilds{}, err
	}
	defer a.snapshotBuildQuerySem.Release(1)

	return db.GetSnapshotBuilds(ctx, a.sqlcDB, teamID, sandboxID)
}
