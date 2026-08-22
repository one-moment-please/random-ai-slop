I asked an AI: "can you write a bash script that checks the needed steps to ensure transcoding works on jellyfin, such as checking what user jellyfin is running at and if it has the correct user permissions and groups?"
and a follow up: "can you add checking for quick sysn, nvenc, and vaapii and doing the diagnostics as to whichever one is available?"

This is the result. It might work, it might not work. It probably won't bork your system

Running it
```bash
chmod +x jellyfin-hw-transcode-check.sh
sudo ./jellyfin-hw-transcode-check.sh
```

Or give it your media path:
```bash
sudo ./jellyfin-hw-transcode-check.sh /mnt/media
```
For a nonstandard transcode directory:
```
sudo TRANSCODE_PATH=/mnt/jellyfin-transcodes \
    ./jellyfin-hw-transcode-check.sh /mnt/media
```
What I would pay particular attention to
For Intel, the important sequence is:
```
Intel GPU detected
        ↓
/dev/dri/renderD128 exists
        ↓
jellyfin user can access renderD128
        ↓
vainfo successfully initializes
        ↓
h264_qsv exists
        ↓
actual h264_qsv encode succeeds
```
That's particularly useful because Jellyfin's current documentation identifies QSV as the preferred Linux method on supported mainstream Intel hardware, while VA-API remains important for compatibility and older Intel generations. 
J
Jellyfin

For NVIDIA:
```
NVIDIA GPU detected
        ↓
nvidia-smi works
        ↓
jellyfin user can run nvidia-smi
        ↓
h264_nvenc exists
        ↓
actual NVENC encode succeeds
```
Jellyfin's current NVIDIA documentation says NVENC/NVDEC is the Linux/Windows acceleration path for NVIDIA, and it does not require a connected display. 
J
Jellyfin

For AMD/Intel VA-API:
```
/dev/dri/renderD128
        ↓
jellyfin user can access it
        ↓
VA-API driver initializes
        ↓
h264_vaapi exists
        ↓
actual VA-API encode succeeds
```
The vainfo portion is intentional: Jellyfin's Intel documentation specifically uses vainfo --display drm --device /dev/dri/renderD128 to verify the driver and supported VA-API profiles. 
J
Jellyfin
+1

One caveat: the script tests encoding, which is excellent for determining whether the accelerator is actually usable, but it doesn't exhaustively test every decode/encode codec combination. For example, a GPU may successfully encode H.264 while lacking the hardware support you need for a particular HEVC/AV1 workload.

