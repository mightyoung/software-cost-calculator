Superseded by ../a17-concurrency-checkpoint-20260923-v2/report.json.

The original cancellation cases injected CANCELLED from createArtifact and did not exercise exportBundle's checkpoint callback. The revised harness requests cancellation after the selected private volume is published and observes it through the production checkpoint. Original report retained for audit; do not use its cancellation result as checkpoint coverage.
