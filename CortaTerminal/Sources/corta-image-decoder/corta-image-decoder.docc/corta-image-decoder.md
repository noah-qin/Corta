# ``corta_image_decoder``

Decodes one Kitty graphics PNG for the app, in a sandboxed process.

## Overview

A PNG a terminal prints is hostile input, and ImageIO is a large C
parser. The app hands the encoded bytes to this helper, which enters the
`pure-computation` sandbox profile before reading them and returns the
decoded pixels through a shared mapping, so a fault in the decoder runs
without Corta's privileges (`docs/SECURITY.md` §4.2). It is never run by
hand.
