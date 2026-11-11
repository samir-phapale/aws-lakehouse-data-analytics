# Sourced by the other scripts: Terraform outputs of the main root and a Glue job runner.

# pwd -W gives a C:/ path in Git Bash, so Windows terraform finds it even with MSYS_NO_PATHCONV set
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && { pwd -W 2>/dev/null || pwd; })"
TF_DIR="${ROOT}/infrastructure/terraform"
PYTHON="${PYTHON:-python}"

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

# run_glue_job <job> [arguments-json]: starts a run and waits for it; returns 1 if it does not succeed
run_glue_job() {
  local job="$1" args="${2:-}" run_id state
  local start=(aws glue start-job-run --job-name "$job" --query JobRunId --output text)
  if [[ -n "$args" ]]; then
    start+=(--arguments "$args")
  fi
  run_id="$(MSYS_NO_PATHCONV=1 "${start[@]}")"
  echo "Started Glue job ${job} (${run_id})${args:+ with ${args}}"
  while true; do
    state="$(aws glue get-job-run --job-name "$job" --run-id "$run_id" --query JobRun.JobRunState --output text)"
    case "$state" in
      SUCCEEDED) echo "  ${job}: ${state}"; return 0 ;;
      FAILED|ERROR|TIMEOUT|STOPPED)
        echo "  ${job}: ${state}" >&2
        aws glue get-job-run --job-name "$job" --run-id "$run_id" --query JobRun.ErrorMessage --output text >&2
        return 1 ;;
      *) echo "  ${job}: ${state}"; sleep 30 ;;
    esac
  done
}
