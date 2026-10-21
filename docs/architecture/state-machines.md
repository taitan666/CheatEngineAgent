# State machines

## Task

| State | Allowed successors |
|---|---|
| created | queued, canceling |
| queued | claimed, waiting, canceling |
| claimed | running, recovering, canceling |
| running | verifying, waiting, recovering, canceling, finished-failed |
| verifying | finished, running, waiting, recovering, canceling |
| waiting | queued, running, verifying, recovering, canceling, finished-failed |
| recovering | queued, running, verifying, waiting, canceling, finished-failed |
| canceling | waiting, finished-canceled |
| finished | none |

Only verification can produce success or partial success. Finished tasks require an outcome; active tasks require a null outcome.

## Effect

`planned → executing → applied | rejected | unknown`

Unknown can become applied or rejected only through trusted reconciliation, or return to executing when policy proves retry safety. Compensation is a new Effect and never erases the original.

