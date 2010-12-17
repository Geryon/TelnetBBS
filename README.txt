------------------------
TelnetBBS Server
telnetbbs.pl

Nicholas DeClario 
nick@declario.com
http://nick.declario.com

December 2010
$Id: README.txt,v 1.2 2010-12-17 20:15:23 nick Exp $
-------------------------

About
-----
TelnetBBS Server is a perl-based telnet server that utilizes DOSBox to run a BBS from.  The goal is to make this process as seamless as possible as little time should be spent in configuring the system to answer calls as oppossed to building the actual BBS.

History
-------
Back in the 90's I ran a local BBS and have always regreted taking it down.  I had finished college and was moving out and running a BBS was no longer an option.  Especially seeing I would not longer be living in the same state that the BBS was originally in.  To make matters worse it was the late 90s and the standalone BBS just couldn't compete.  Who wanted LORD when The Realm was picking up speed?  Who wanted upload/download ratios, and message boards limited to the few hundred local users versus online forums limited to anyone with an internet conncetion.  

A number of years later I moved away from DOS/Windows-based operating systems and really wanted to get my BBS up and running.  I made a few somewhat weak attempts at doing so and failed.  Finally I decided I am going to get this working.  I originally wanted to put my old BBS back up.  I tried reading up on ways to get DOS networked and things of that nature.  I even tried setting WinXP up in a virtual box instance and use someone elses virtual modem and connecting software, which worked but was clunky in a VM and ate up a ton of memory.  I wanted an elegant Linux solution to this, so I ended up writing this one.


Quick Install
-------------
The quick and dirty way to get all this running is to install DOSBox, your favorite fossil driver (I found FOSS works best) and grab your favorite BBS software.  I used Cott Lang's Renegade BBS back in the day and I am continuing to do so.

For a basic set up, that I don't recommend keeping but it's a good starting point, make sure you are running X and edit the include DOSBox template file, 'dosbox.conf.template'.

You will need to make changes to the autoexec section to load your fossil driver and start your BBS.  The '__NODE__' will be replaced the with the appropriate node when the BBS is started.  What you may need to do is configure your BBS to answer the (virtual) modem on com1.  A number of BBS software are configured by default for this.  

At this point start the server, './telnetbbs.pl'.  The server will start up and tell you what port it's running on, 3023 is the default.  

Now take your favorite terminal program, I _highly_ recommend SyncTERM, and point it to localhost on port 3023 and you should get a login prompt.

There are many more options and configurations that can be made, please read the detailed 'Install' section below for more details.  Additionally the main configuration file goes through, in detail, all of the configuration options.

Install
-------

