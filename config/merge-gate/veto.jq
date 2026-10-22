# merge-gate.yml's owner-veto program (jq). stdin: {owner, reviews, timeline}: the
# PR's reviews API list and issue timeline. Prints true when the owner's veto is
# active. The owner's latest review that is an approval, a request for changes
# or a dismissal decides. A request for changes holds. A dismissal lifts it only
# when the owner made it, or when the dismissed review was an approval (a push
# dismisses a stale approval). A dismissal with no event, or by anyone else, holds.
. as $in
| ($in.owner | ascii_downcase) as $o
| [$in.timeline[] | select(.event == "review_dismissed")] as $dis
| [$in.reviews[]
    | select(((.user.login // "") | ascii_downcase) == $o)
    | . as $r
    | (if .state == "APPROVED" then "lifted"
       elif .state == "CHANGES_REQUESTED" then "held"
       elif .state == "DISMISSED" then
         ([$dis[] | select(.dismissed_review.review_id == $r.id)] | last) as $e
         | if $e == null then "held"
           elif (($e.dismissed_review.state // "") | ascii_downcase) == "approved" then "lifted"
           elif ((($e.actor.login // "") | ascii_downcase) == $o) then "lifted"
           else "held" end
       else empty end) as $eff
    | {at: .submitted_at, id: .id, eff: $eff}]
| sort_by([.at, .id])
| last
| . != null and .eff == "held"
