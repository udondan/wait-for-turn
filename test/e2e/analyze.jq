# Checks the invariants of wait-for-turn on what a scenario recorded.
#
# Inputs: $snaps (snapshots.jsonl as an array, see observe.sh), $final
# (final.json, see collect.sh), $config (repository variables of the runs) and
# $max_gap (seconds the shared resource may stay unused while a run waits).
# Output: the report, with .checks as a list of {name, ok, detail}.

def ts: if . == null then null else sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 end;
def iso: if . == null then null else todate end;
def workflow_file: (. // "") | split("/") | last;

$final[0] as $final
| $config[0] as $config
| ($config.POLL // "10" | tonumber) as $poll
| ($config.MERGE_WAIT // "10" | tonumber) as $merge_wait
| ($config.NO_PR_WEIGHT // "0" | tonumber) as $no_pr_weight
| ($config.LABEL_WEIGHTS // "" | split("\n")
  | map(capture("^\\s*(?<l>.+?)\\s*=\\s*(?<w>[+-]?[0-9]+)\\s*$")? | {(.l): (.w | tonumber)})
  | add // {}) as $weights

# The pull request of a run: the API drops it once the pull request is closed,
# so fall back to what the observer saw, then to the pull request whose head
# commit the run tested.
| ($snaps | map(.runs[] | select(.pr != null) | {key: (.id | tostring), value: .pr}) | from_entries) as $run_pr
| ([$snaps[].prs[], $final.prs[]] | map({key: .head_sha, value: .number}) | from_entries) as $sha_pr

# Label weight of a pull request at time t, from the last snapshot before t.
| def weight($pr; $t):
    if $pr == null then $no_pr_weight
    else
      (([$snaps[] | select((.t | ts) <= $t + 5) | .prs[] | select(.number == $pr) | .labels] | last)
        // ([$final.prs[] | select(.number == $pr) | .labels] | first) // [])
      | (map($weights[.] // 0) | add) // 0
    end;

[$final.runs[] | {
  id, workflow: (.path | workflow_file), event, head_sha, conclusion, html_url,
  pr: (if .event == "pull_request" then (.pr // $run_pr[.id | tostring] // $sha_pr[.head_sha]) else null end),
  jobs: ($final.jobs[.id | tostring] // [])
}] as $runs

# One entry per attempt of a run: its wait job and the "Use resource" step.
| [$runs[] | . as $r | ($r.jobs | group_by(.run_attempt))[] | . as $js
  | ($js | map(select(.name | startswith("wait-for-turn"))) | first) as $w
  | ($js | map(select(.name == "deploy")) | first) as $d
  | ($d.steps // [] | map(select(.name == "Use resource")) | first) as $u
  | select($w != null and $w.conclusion != "skipped")
  | {
      run: $r.id, attempt: $js[0].run_attempt, workflow: $r.workflow, pr: $r.pr, event: $r.event,
      start: ($js | map(.created_at | ts) | min),
      end: ($js | map(.completed_at | ts) | max),
      wait: {start: ($w.started_at | ts), end: ($w.completed_at | ts), conclusion: $w.conclusion, job: $w.id},
      deploy: (if $u != null and $u.started_at != null and $u.conclusion != "skipped"
        then {start: ($u.started_at | ts), end: ($u.completed_at | ts), conclusion: $u.conclusion} else null end)
    }] as $attempts

# Turns, from the lock refs the observer saw. The lock commit's date is when
# the run took the turn.
| ($snaps | map(.locks[]) | group_by("\(.workflow)/\(.n)")
  | map({workflow: .[0].workflow, n: .[0].n, runs: (map(.run) | unique), run: .[0].run, pr: .[0].pr, t: (.[0].created | ts)})
  | sort_by(.workflow, .n)) as $turns

| ($turns | map(. as $turn | . + {weight: weight(.pr; .t)})) as $turns

# Mutual exclusion: the "Use resource" steps of a workflow never overlap.
| [$attempts | map(select(.deploy != null)) | group_by(.workflow)[] | sort_by(.deploy.start) | . as $d
  | range(1; length) as $i
  | ($d[:$i] | max_by(.deploy.end)) as $prev
  | select($d[$i].deploy.start < $prev.deploy.end)
  | "run \($prev.run) (#\($prev.pr)) \($prev.deploy.start | iso)-\($prev.deploy.end | iso) and run \($d[$i].run) (#\($d[$i].pr)) from \($d[$i].deploy.start | iso)"] as $overlaps

# Lock integrity: each lock number was taken by one run, and the runs used the
# resource in the order of their lock numbers.
| [$turns[] | select((.runs | length) > 1) | "lock \(.workflow)/\(.n) by runs \(.runs | join(", "))"] as $double_locks
| [$attempts | map(select(.deploy != null)) | group_by(.workflow)[] | sort_by(.deploy.start) | map(.run)
  | reduce .[] as $r ([]; if last == $r then . else . + [$r] end)] as $deploy_orders
| [$turns | group_by(.workflow)[] | map(.run)] as $lock_orders
| [$deploy_orders[] as $d | select(($lock_orders | index([$d])) == null)
  | "deploy order \($d | join(" ")), lock orders \($lock_orders | map(join(" ")) | join(" / "))"] as $order_mismatch

# The turn is only taken after the previous holder's run completed, and, when
# it succeeded with auto-merge on, after its pull request was merged (unless
# merge-wait-minutes ran out).
| [$turns | group_by(.workflow)[] | . as $t | range(1; length) as $i
  | $t[$i - 1] as $prev | $t[$i] as $cur
  | ([$attempts[] | select(.run == $prev.run and .start <= $cur.t)] | max_by(.attempt)) as $held
  | select($held != null)
  | ($final.prs | map(select(.number == $prev.pr)) | first) as $pull
  | ($pull.merged_at | ts) as $merged
  | ([$snaps[] | .prs[] | select(.number == $prev.pr) | .auto_merge] | any) as $auto
  | ([$runs[] | select(.id == $prev.run)] | first) as $prev_run
  | if $cur.t < $held.end - 2 then
      "run \($cur.run) (#\($cur.pr)) took lock \($cur.n) at \($cur.t | iso) before run \($prev.run) completed at \($held.end | iso)"
    elif $auto and $merged != null and $prev_run.conclusion == "success" and $merged - $held.end < $merge_wait * 60 and $cur.t < $merged then
      "run \($cur.run) (#\($cur.pr)) took lock \($cur.n) at \($cur.t | iso) before #\($prev.pr) was merged at \($merged | iso)"
    else empty end] as $early

# Order: when a run took the turn, no run that was waiting long enough to be
# seen had a higher weight, or the same weight and an earlier start. Runs of a
# pull request with a newer run are left out of the queue.
| [$turns[] as $turn
  | ([$attempts[] | select(.run == $turn.run and .start <= $turn.t)] | max_by(.attempt)) as $me
  | select($me != null)
  | weight($me.pr; $turn.t) as $my_weight
  | $attempts[] as $a
  | select($a.workflow == $turn.workflow and $a.run != $turn.run and $a.start < $turn.t - 15 and $a.wait.end > $turn.t + 5)
  | select([$attempts[] | select(.pr != null and .pr == $a.pr and .run > $a.run and .start < $turn.t)] | length == 0)
  | weight($a.pr; $turn.t) as $w
  | select($w > $my_weight or ($w == $my_weight and $a.start < $me.start - 2))
  | "lock \($turn.n) at \($turn.t | iso) went to run \($turn.run) (#\($turn.pr), weight \($my_weight)), but run \($a.run) (#\($a.pr), weight \($w)) was waiting since \($a.start | iso)"] as $order_violations

# Idle resource: the time between a deploy ending and the next one starting
# while the next run was already there.
| [$attempts | map(select(.deploy != null)) | group_by(.workflow)[] | sort_by(.deploy.start) | . as $d
  | range(1; length) as $i
  | {gap: ($d[$i].deploy.start - ([$d[$i - 1].deploy.end, $d[$i].start] | max)), run: $d[$i].run, pr: $d[$i].pr, at: ($d[$i - 1].deploy.end | iso)}] as $gaps
| ($gaps | max_by(.gap)) as $max_gap_seen

# Commit statuses: one sequence per run (the target URL is the run), starting
# pending and ending with the state matching the wait job of its last attempt.
| [$runs[] | . as $r
  | ($attempts | map(select(.run == $r.id)) | max_by(.attempt)) as $last
  | {
      run: $r.id, pr: $r.pr, workflow: $r.workflow, event: $r.event, head_sha: $r.head_sha, html_url: $r.html_url,
      attempts: [$attempts[] | select(.run == $r.id) | {attempt, wait: {conclusion: .wait.conclusion, start: (.wait.start | iso), end: (.wait.end | iso)}, deploy: (if .deploy then .deploy + {start: (.deploy.start | iso), end: (.deploy.end | iso)} else null end)}],
      wait_conclusion: $last.wait.conclusion,
      statuses: [$final.statuses[$r.head_sha][]? | select(.target_url | endswith("/runs/\($r.id)")) | {context, state, description, at: .created_at}],
      annotations: [$r.jobs[] | select(.name | startswith("wait-for-turn")) | $final.annotations[.id | tostring][]?]
    }
  | select(.wait_conclusion != null)] as $report_runs

| [$report_runs[] | select(.workflow == "pipeline.yml") | . as $r
  | ({success: "success", failure: "failure", cancelled: "error"}[$r.wait_conclusion]) as $expected
  | if ($r.statuses | length) == 0 then "run \($r.run) (#\($r.pr)): no status, wait job \($r.wait_conclusion)"
    elif $r.statuses[0].state != "pending" then "run \($r.run) (#\($r.pr)): first status \($r.statuses[0].state)"
    # A run of an outdated commit can fail as outdated just before its
    # concurrency group cancels it: the job ends cancelled, the status failure.
    elif $r.wait_conclusion == "cancelled" and ($r.statuses | last | .state == "failure" and (.description | startswith("Outdated, a newer commit"))) then empty
    elif $expected != null and ($r.statuses | last | .state) != $expected then
      "run \($r.run) (#\($r.pr)): last status \($r.statuses | last | "\(.state) \(.description)"), wait job \($r.wait_conclusion)"
    else empty end] as $status_problems

| ($snaps | last | .runs // [] | map(select(.status != "completed"))) as $still_active

| {
    turns: [$turns[] | {workflow, n, run, pr, weight, t: (.t | iso)}],
    runs: $report_runs,
    prs: $final.prs,
    gaps: $gaps,
    checks: [
      {name: "mutual-exclusion", ok: (($overlaps | length) == 0 and ($final.overlaps | length) == 0),
        detail: (if ($overlaps + $final.overlaps | length) == 0 then "\([$attempts[] | select(.deploy != null)] | length) deploys, none overlapped"
          else ($overlaps + $final.overlaps | join("; ")) end)},
      {name: "lock-integrity", ok: (($double_locks + $order_mismatch | length) == 0),
        detail: (if ($double_locks + $order_mismatch | length) == 0 then "\($turns | length) locks, each taken once, deploys in lock order"
          else ($double_locks + $order_mismatch | join("; ")) end)},
      {name: "release", ok: (($early | length) == 0),
        detail: (if ($early | length) == 0 then "every turn taken after the holder completed (and its auto-merge pull request merged)" else ($early | join("; ")) end)},
      {name: "order", ok: (($order_violations | length) == 0),
        detail: (if ($order_violations | length) == 0 then "every turn went to the highest weight, then earliest run" else ($order_violations | join("; ")) end)},
      {name: "commit-status", ok: (($status_problems | length) == 0),
        detail: (if ($status_problems | length) == 0 then "\([$report_runs[] | select(.workflow == "pipeline.yml")] | length) runs: pending first, final state matches the wait job" else ($status_problems | join("; ")) end)},
      {name: "idle-gap", ok: (($max_gap_seen.gap // 0) <= $max_gap),
        detail: (if $max_gap_seen == null then "fewer than 2 deploys" else "longest idle \($max_gap_seen.gap)s before run \($max_gap_seen.run) (#\($max_gap_seen.pr)) at \($max_gap_seen.at), limit \($max_gap)s" end)},
      {name: "all-completed", ok: (($still_active | length) == 0),
        detail: (if ($still_active | length) == 0 then "no run left active" else "still active: \($still_active | map(.id) | join(", "))" end)}
    ]
  }
