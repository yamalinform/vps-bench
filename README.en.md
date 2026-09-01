*[По-русски](README.md)*

# vpsbench: the same measurement on any VPS

You have just rented a server and you want to know what you actually got. What CPU is
in there, how fast the disk really is, what the network looks like, whether the hosting
page told you the truth. vpsbench answers that with numbers.

The point of it is comparability. Every machine runs exactly the same checks, with
exactly the same versions of the measuring tools. You can put two reports side by side
and read them line by line.

## How to run it

```bash
curl -fsSL https://raw.githubusercontent.com/yamalinform/vps-bench/main/run.sh -o run.sh && bash run.sh
```

It asks the rest itself: whether the machine is free, how thorough you want to be,
whether you have a second machine for the network test. A quick check takes about five
minutes, a thorough one about forty.

## What it does to your machine

**It installs Docker and nothing else**, and only if Docker is missing and you agreed.
All the measuring tools (fio, sysbench, iperf3, openssl and a dozen more) live inside
the image and never land on your machine.

**It leaves a folder with reports.** Everything else is cleaned up: the image is
removed, Docker is uninstalled if we were the ones who installed it. If Docker was
already there, it stays untouched.

**Only one thing can change your machine for good:** a system upgrade. The tool offers
it, but the default answer is no, and it cannot roll an upgrade back. A reboot is a
separate question, and its default is no as well. With no terminal attached (a script,
for example) it will never upgrade or reboot your machine until you say so explicitly
with a flag.

> ⚠️ **The container here is a way to deliver tools, not a sandbox.**
> To measure the machine it needs `--network host`, `--privileged` and access to the
> disks. Otherwise it would measure the container instead of the machine. If those
> permissions are not acceptable to you, this tool is not for you, and it is fairer
> to say so here than to bury it in the small print.

## Where it connects

To exactly three places, and the list is printed on screen before anything starts:

* `ghcr.io`, for the image with the measuring tools;
* your own system repositories, and only if Docker has to be installed;
* speed test endpoints: your second machine if you name one, plus public ones
  (Cloudflare, Debian and Yandex mirrors).

**Results are never uploaded anywhere.** No telemetry, no published report, no
accounts. That is exactly why we did not build on the popular benchmark suites: they
publish the result, and with it a fingerprint of your machine and your network.

## What you get

In `~/vpsbench-report-<label>/`:

| File | What it is |
|---|---|
| `<label>.md` | the machine profile: readable in a terminal, good for `diff` |
| `<label>.html` | the same thing for reading with your eyes, opens with a double click, no internet needed |
| `<label>.json` | machine readable, this is what a multi machine comparison is built from |
| `raw-run/` | raw measurement data, the report can be rebuilt from it |

Next to every number you get the spread across repeats and a reliability mark. A spread
above 20% is labelled UNRELIABLE: such a median cannot be treated as a property of the
machine, and it is better to see that than not to know it.

The report has the same structure on every machine, because it is built from a fixed
list of metrics rather than from whatever happened to be collected. A metric that could
not be measured stays in place as a "not measured" line instead of disappearing.
Otherwise two reports could not be compared line by line.

## Network test: you need a second machine

Speed is measured between two machines. The second one does not have to be a server,
your laptop will do:

```bash
bash run.sh --agent
```

It brings up the receiving side (three ports, zero packages installed on the machine)
and holds it until you press Ctrl-C. On the first machine, when it asks about the
network, give it that address.

Without a second machine the network is still measured, against public endpoints. But
that measures the path to somebody else's service rather than your own link. Those
numbers go into a separate section and are never mixed with the ones from your second
machine.

## If you want it without questions

For repeat runs and for scripts, every answer can be given as a flag:

| Flag | What it does |
|---|---|
| `--vantage NAME` | label for this machine, goes into the report instead of the hostname |
| `--depth quick\|full` | quick check or thorough one |
| `--impact bench\|observe` | full load, or a gentle mode for a machine that is in service |
| `--target LABEL:ADDRESS` | second machine with the receiving side running |
| `--no-network` | skip the network test entirely |
| `--yes` | agree to start the measurement |
| `--install-docker yes\|no` | whether to install Docker without asking |
| `--update yes\|no` | whether to upgrade the system. Default is no |
| `--reboot yes\|no` | whether to reboot the machine. Default is no |

If there is no terminal and no flag, the safe answer is taken, and the tool says so out
loud instead of doing it quietly.

## Comparing several machines

```bash
python3 assemble.py --compare results/A results/B --out comparison.md
python3 dashboard/build.py folder-with-json/ --out dashboard.html
```

The comparison first checks whether comparing is meaningful at all: same tool version,
same measuring tool versions, same run mode, same public endpoints. A difference that
does not exceed the metric's own spread is reported as insignificant, because that is
noise rather than a difference between machines.

## What this tool does not do

* **It does not tell you a machine is good.** It shows numbers and flags the unreliable
  and the insignificant ones. The conclusion is yours to draw.
* **It does not promise that disk numbers describe the disk.** On a virtual machine the
  `O_DIRECT` flag inside the guest does not switch off the host cache. With a small work
  file the tool warns about it, and on `tmpfs` or `overlay` it refuses to measure at all.
* **It does not calibrate the stall detection threshold.** The report prints the data
  you need to choose a threshold, but it does not choose one for you.
* **It does not measure your application's transport.** It estimates the potential of
  the machine, not how a particular application performs on it.

## Requirements

Linux x86_64 with Docker (or with `apt` so it can be installed), root or `sudo`, and
1.5 GB of free space. The distribution does not matter: the versions of the measuring
tools come from the image, not from your machine's repositories.

## License

MIT, see [LICENSE](LICENSE).
