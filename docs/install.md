# Install

Needs an Apple Silicon Mac on macOS 15 or later (FluidAudio's diariser hits a Core ML bug that
Apple fixed in macOS 15). Oatcake isn't notarised by Apple, so macOS won't open a copy downloaded
with a browser until you allow it. There are two ways to install it.

**From Terminal.** Paste this:

```sh
curl -fsSL https://github.com/a8cteam51/oatcake/releases/latest/download/install.sh | sh
```

It downloads the latest release over HTTPS (it won't follow a redirect to anything else), checks
its checksum and that it's signed with Oatcake's own release certificate, puts Oatcake in
Applications (or wherever it's installed already, or `~/Applications` if you can't write to
Applications) and opens it. The installer comes from the release itself. Files that curl
downloads don't get macOS's quarantine flag, so there's no warning to get past. Run it again to
update to the latest release; it quits Oatcake first if it's open. When that version is installed
already, it just opens it; when a newer one is (because a release was withdrawn, say), it says so
and installs nothing. Two settings go before `sh`: `OATCAKE_REINSTALL=1` installs the same version
again, and `OATCAKE_INSTALL_DIR=<folder>` installs somewhere else:

```sh
curl -fsSL https://github.com/a8cteam51/oatcake/releases/latest/download/install.sh | OATCAKE_REINSTALL=1 sh
```

**By hand.**

1. Download `Oatcake-v…-arm64.zip` from the
   [latest release](https://github.com/a8cteam51/oatcake/releases/latest) and open it to unzip it.
2. Drag Oatcake into your Applications folder and open it. macOS says it couldn't check Oatcake
   for malware and doesn't open it. Choose Done, not Move to Trash.
3. Open System Settings › Privacy & Security, scroll down to Security, and click **Open Anyway**
   beside the note about Oatcake.
4. Open Oatcake again and choose **Open Anyway**. macOS remembers this, and Oatcake updates itself
   from then on (if it's in a folder you can't write to, Settings › Updates gives the install
   line instead).

## First recording

Either way, the first recording asks for microphone and system-audio permission for Oatcake. The
first recording after updating from a version before 0.5.0 asks once more (see
[Security](security.md) for why).

There's nothing to sign in to and no key to paste: the models run on your Mac, and Oatcake
fetches them itself, into `~/Library/Application Support/Oatcake/models`. They start downloading
when you start your first recording: the language model that writes summaries (Qwen3.6 35B-A3B,
20.5 GB, on a Mac with 32 GB of memory or more; Qwen3.5 4B, 3.0 GB, on one with less) and the speech models
that write the live transcript. The ones that tell voices apart follow when the call is processed
(the speech models come to about 500 MB in all; with the live transcript turned off, all of them
wait until then). The call's screen shows how far the download has got, and Settings › Models
can start it ahead of time (**Download now**) or stop it. Oatcake checks there's room on the disk
first. See [Speech models](models.md#speech-models) and [Language model](models.md#language-model).

## Before you record

Tell the people on the call that you're recording. Oatcake records their side of it, writes down
what they say and, once you've put a name to a voice, keeps a fingerprint of that voice on your
Mac so it can recognise them next time (Settings › People lists them, and **Forget…** removes
one). Whether you need their agreement depends on where you and they are; asking costs nothing.
