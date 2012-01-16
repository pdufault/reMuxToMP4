#!/bin/bash

# Phil Dufault (2008-2009) phil@dufault.info
# http://dufault.info

VERSION="0.5.3-r1"

log="$PWD/log.$(date +%T-%F).txt"

cecho() {
	echo -e "$1"
	echo -e "$1" >>"$log"
	tput sgr0;
}

ncecho () {
	echo -ne "$1"
	echo -ne "$1" >>"$log"
	tput sgr0
}

sp="/-\|"
spinny () {
	echo -ne "\b${sp:i++%${#sp}:1}"
}

progress () {
	ncecho "  ";
	while [ /bin/true ]; do
		kill -0 $pid 2>/dev/null;
		if [[ $? = "0" ]]; then
			spinny
			sleep 0.25
		else
			ncecho "\b\b";
			wait $pid
			retcode=$?
			echo "$pid's retcode: $retcode" >> "$log"
			if [[ $retcode = "0" ]]; then
				cecho success
			else
				cecho failed
				echo -e " [i] Showing the last 5 lines from the logfile ($log)...";
				tail -n5 "$log"
				exit 1;
			fi
			break 2;
		fi
	done
} 

cecho " [x] reMuxToMP4 script, v$VERSION, written by Phil Dufault\n [x] Contact him at: http://www.dufault.info"

if [[ $# -lt 1 ]];
then
	cecho ' [i] Please supply a filename to remux to MP4, and the target filename optionally';
	exit 1;
fi

for i in mplayer normalize-audio mencoder mkvinfo mkvextract neroAacEnc bbe mp4creator; do
	if hash -r "$i" >/dev/null 2>&1; then
		ncecho;
	else
		cecho " [i] The $i command is not available, please install the required packages.";
		DIE=1;
	fi
done

if [[ $DIE ]]; then
	cecho " [i] Needed programs weren't found, exiting...";
	exit 1;
fi		

SOURCE=$1
if [[ -z $2 ]];
then
	DEST="${1%.*}.mp4"
else
	DEST=$2
fi
shift 2;

cecho " [x] Source filename: $SOURCE\n [x] Destination filename: $DEST";

if [[ -f $DEST ]];
then
	cecho ' [i] Destination filename already exists -- please delete and rerun the script, or select another destination';
	exit 1;
fi

identify() {
	mplayer -frames 0 -identify -ao null -vo null "$SOURCE" 2>/dev/null > /tmp/info.$$.txt
	grep ^ID_VIDEO /tmp/info.$$.txt >/dev/null && VIDEO=1
	grep ^ID_AUDIO /tmp/info.$$.txt >/dev/null && AUDIO=1

	WIDTH=$(grep ^ID_VIDEO_HEIGHT /tmp/info.$$.txt | sed 's/^ID_VIDEO_HEIGHT=//g')
	HEIGHT=$(grep ^ID_VIDEO_WIDTH /tmp/info.$$.txt | sed 's/^ID_VIDEO_WIDTH=//g')
	FPS=$(grep ^ID_VIDEO_FPS /tmp/info.$$.txt | sed 's/^ID_VIDEO_FPS=//g')
	VIDEO_CODEC=$(grep ^ID_VIDEO_CODEC /tmp/info.$$.txt | awk -F= '{print $2}')
	AUDIO_CHANNELS=$(grep ^ID_AUDIO_NCH /tmp/info.$$.txt | sort -r | head -n1 | awk -F= '{print $2}')
	AUDIO_CODEC=$(grep ^ID_AUDIO_CODEC /tmp/info.$$.txt | awk -F= '{print $2}')
	DEMUXER=$(grep ^ID_DEMUXER /tmp/info.$$.txt | awk -F= '{print $2}')
	rm -f /tmp/info.$$.txt

	size=$(du -m $SOURCE | awk '{print $1}');
	if [[ -z $VIDEO ]];
	then
		cecho " [-] Missing a video stream -- please check the source file.";
		exit 1;
	else
		cecho " [x] Video stream found, $HEIGHT x $WIDTH @ $FPS fps, using $VIDEO_CODEC";
	fi

	if [[ -z $AUDIO ]];
	then
		cecho " [-] Missing a audio stream -- please check the source file.";
		exit 1;
	else
		cecho " [x] Audio stream found, $AUDIO_CHANNELS audio channels, using $AUDIO_CODEC"; 
	fi
	cecho " [x] Muxed in $DEMUXER format, source file is ${size}MB";
}

dumpAndReencodeAudio() {
	ncecho " [x] Dumping the audio...";
	mplayer "$SOURCE" -vo null -vc null -nocorrect-pts -ao "pcm:fast:file=$DEST.wav" -channels 2 >>"$log" 2>&1 &
	pid=$!;progress $pid

	ncecho " [x] Normalizing the audio...";
	normalize-audio --peak "$DEST.wav" >>"$log" 2>&1 &
	pid=$!;progress $pid

	ncecho " [x] Encoding the audio to low-complexity AAC...";
	neroAacEnc -lc -if "$DEST.wav" -of "$DEST.m4a" >>"$log" 2>&1 &
	pid=$!;progress $pid

	rm -f "$DEST.wav"
	ncecho " [x] Extracting audio from MP4 container (silly neroAacEnc)...";
        mp4creator --extract=1 "$DEST.m4a" >>"$log" 2>&1 &
	pid=$!;progress $pid

	mv "${DEST}.m4a.t1" "$DEST.aac"
	rm -f "$DEST.m4a"
	AUDIO_FILE="$DEST.aac"
}

dumpVideo() {
	if [[ $DEMUXER = "mkv" ]]; then
		ncecho " [x] Extracting the video from the mkv...";
		TRACKNUM=$(mkvinfo "$SOURCE" | grep -B2 "Track type: video"|head -n1|awk -F": " '{print $2}')
		mkvextract tracks "$SOURCE" "$TRACKNUM":"$DEST.264" >>"$log" 2>&1 &
	else
		cecho " [x] Dumping the video...failed\n [i] This aspect of the script is still broken, dying.";
		exit 1;
	fi
	pid=$!;progress $pid
	VIDEO_FILE="$DEST.264"
	ncecho " [x] Changing the h264 video stream profile from 5.1 to 4.1...";
	bbe -e "r 7 \41" --output="$VIDEO_FILE.new" "$VIDEO_FILE" >>"$log" 2>&1 &
	pid=$!;progress $pid
	ncecho " [x] Deleting the old video source...";
	rm -f "$VIDEO_FILE" >>"$log" 2>&1 &
	pid=$!;progress $pid
	ncecho " [x] Moving new video stream to proper filename...";
	mv "$VIDEO_FILE.new" "$VIDEO_FILE" >>"$log" 2>&1 &
	pid=$!;progress $pid
}

mux() {
	ncecho " [x] Muxing video stream at $FPS fps...";
	mp4creator --create="$VIDEO_FILE" "$DEST" -r "$FPS" >>"$log" 2>&1 &
	pid=$!;progress $pid

	ncecho " [x] Muxing the audio stream in...";
	mp4creator --create="$AUDIO_FILE" "$DEST" >>"$log" 2>&1 &
	pid=$!;progress $pid

	ncecho " [x] Deleting audio and video tempfiles...";
	rm -f "$VIDEO_FILE" "$AUDIO_FILE" >>"$log" 2>&1 &
	pid=$!;progress $pid
}

finish() {
	cecho " [o] All done!";
}

identify;
if [[ $VIDEO_CODEC = "ffh264" ]]; then
	dumpAndReencodeAudio;
	dumpVideo;
	mux;
else
	cecho " [i] Video is not in h264 stream!";
	exit 0;
fi
finish;

rm -f "$log"
