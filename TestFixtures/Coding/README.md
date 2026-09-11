# Live Coding replay fixtures

`interview-turns.json` is one real recorded interview (962 turns, ~48 minutes, both
speakers) exported from a call archive, kept as the offline corpus for the Live
Coding pipeline.

Replay it through the segmenter, the intent classifier and the director:

```sh
cd Intelligence
CODING_TRANSCRIPT=../TestFixtures/Coding/interview-turns.json \
  swift test --filter CodingReplayTests
```

The trace prints every statement the segmenter emits with the decision the
director made, then a summary. It runs no model and spends no quota — it measures
the part that decides whether a model is asked at all.
