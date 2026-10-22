#!/bin/bash
# tools/shot2.sh out.png steps keys...   (headless screenshot)
out=$1; steps=$2; keys=$3
S=/tmp/claude-1000/-home-stargazer-claude-projects-sf1/ee137fea-8e2e-4d9a-9d99-47ca741c02ef/scratchpad/shots
luajit tools/shot.lua $S/_t.ppm $steps "$keys" || exit 1
python3 -c "
from PIL import Image
im=Image.open('$S/_t.ppm')
f=3 if im.width==320 else 1
im=im.resize((im.width*f,im.height*f),Image.NEAREST); im.save('$out')"
