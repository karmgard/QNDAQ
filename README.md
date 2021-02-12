#QNDAQ

This set of packages is a remote hardware control package. It is designed to 
control the QuarkNet Data Aquisition Card (DAQ) -- which connects to an ionizing
radiation detector (of two types here) -- from a remote computer. It 
also implements a relay chat server (loosely modeled after IRC) that allows 
multiple users to communicate and control the DAQ (and, for the special version 
of the detector known as the CRiL, it allows control of the robotic motors 
so that the detector can be oriented).
   This pacage is written entirely in PERL, and the hardware control aspect 
is done using the SERIAL package. That portion is wrapped in a separate package
that gets called from main with the idea that the chat server and telnet 
monitor could be used for other hardware.
