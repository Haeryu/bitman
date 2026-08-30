# bitman
> [BitLinear](https://github.com/schneiderkamplab/bitlinear) evolved with a genetic algorithm to play Snake.

## Screenshots

![bitman](screenshots/1.gif)
![bitman](screenshots/2.png)
![bitman](screenshots/3.png)

The network uses ternary weights (`-1, 0, 1`) inspired by [BitLinear](https://github.com/schneiderkamplab/bitlinear).

I originally started this after looking for ways to train quantized networks without maintaining full-precision shadow weights. Instead of forcing backpropagation onto it, I went with evolutionary search.

Some of the BitLinear implementation was adapted from my earlier experiment:
[`stoneagemodel`](https://github.com/Haeryu/self_hackathon/tree/master/date20260816/stoneagemodel).

The snake environment and evolutionary approach were inspired by [Learning to Fly](https://pwy.io/posts/learning-to-fly-pt1/).

main.zig: mostly AI-generated glue/demo code.  
bitlinear.zig and the core math/GA code: handwritten.

## Run

```sh
zig build run -Doptimize=ReleaseFast
```

## Evaluate saved champions

```sh
zig build eval -Doptimize=ReleaseFast
```

The training run keeps `bitman_snake.chk` as its resume checkpoint and writes
clean generation snapshots every 50 generations (`bitman_snake_50.chk`,
`bitman_snake_100.chk`, ...). `eval` evaluates every numbered snapshot on the
same 1,000 fixed seeds and prints average food per episode. It also reports a
100-network random ternary baseline using those same seeds.

## Replay

Press `Q` during training to pause evolution and replay the recorded
`parents[0]` action track for the current process. Completed generation
segments are appended to `snake_replay.rep`, which can be played later with:

```sh
zig build replay -Doptimize=ReleaseFast
```

The standalone replay command reads the stored action history from generation
0 (or the first generation present in the file) through the last saved segment.
The replay view supports:

- `Space`: play/pause
- `R`: restart
- `1`-`9`, `0`: jump to 10%-100% of the track
- `,` / `.`: step backward/forward one action
- `[` / `]`: decrease/increase playback speed
- `Q`: return to training, or quit standalone replay
- `Esc`: save the resume checkpoint and quit training; quit standalone replay

## Results

Saved champions were evaluated on the same 1,000 fixed seeds. A baseline of 100 randomly initialized ternary networks was evaluated on the same seeds.

| Model                   | Avg. food / episode | Best food |
| ----------------------- | ------------------: | --------: |
| Random ternary baseline |               0.028 |         2 |
| Generation 50           |               0.335 |         4 |
| Generation 500          |               6.471 |        21 |
| Generation 1000         |              12.209 |        24 |
| Generation 1500         |              14.116 |        24 |
| Generation 2000         |              24.199 |        49 |
| Generation 2400         |          **30.190** |        48 |

Performance is noisy across generations, as expected from evolutionary search, but the overall trend shows a substantial improvement over randomly initialized ternary networks.

The networks are evolved directly with genetic search; training uses no backpropagation or full-precision shadow weights.
