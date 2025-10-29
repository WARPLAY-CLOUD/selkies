mkdir github && cd github && git clone https://github.com/WARPLAY-CLOUD/docker-selkies-egl-desktop.git && git clone https://github.com/WARPLAY-CLOUD/selkies.git && chmod +x *


cd .. && rm -rf selkies && git clone https://github.com/WARPLAY-CLOUD/selkies.git && cd selkies && chmod +x * && ./build-with-docker.sh

cd docker-selkies-egl-desktop && docker build --no-cache .




docker run --name egl -it -d   --gpus 1   --network=host   --tmpfs /dev/shm:rw   -e TZ=UTC   -e DISPLAY_SIZEW=1920   -e DISPLAY_SIZEH=1080   -e DISPLAY_REFRESH=60   -e DISPLAY_DPI=96   -e DISPLAY_CDEPTH=24   -e PASSWD=mypasswd   -e SELKIES_ENCODER=nvh264enc   -e SELKIES_VIDEO_BITRATE=8000   -e SELKIES_FRAMERATE=60   -e SELKIES_AUDIO_BITRATE=128000   -e SELKIES_BASIC_AUTH_PASSWORD=mypasswd   -e SELKIES_TURN_PROTOCOL=udp   -e SELKIES_TURN_PORT=3478   -e SELKIES_TURN_HOST=turn.warplay.cloud   -e SELKIES_TURN_USERNAME=some_user   -e SELKIES_TURN_PASSWORD=some_password   -p 8080:8080   41f200da416e