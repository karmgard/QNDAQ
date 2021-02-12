// Additions to string utilities
String.prototype.chomp = function () {
    return this.replace(/(\n|\r)+$/, '');
};

String.prototype.chop = function () {
    return this.substring(0,this.length-1);
};

String.prototype.reverse = function() {
    splitext = this.split("");
    revertext = splitext.reverse();
    reversed = revertext.join("");
    return reversed;
};

var maxLines   = 50;
var verbose    = true;
var closeDown  = false;
var typingFlag = false;
var cardSocket;
var chatSocket;

var hostname;
var chatPort = 8888;
var cardPort = 8979;


var daqStatus = new Array();
daqStatus['C0'] = null;
daqStatus['SN'] = null;
daqStatus['LT'] = null;
daqStatus['LG'] = null;
daqStatus['AL'] = null;
daqStatus['LK'] = null;
daqStatus['MT'] = null;
daqStatus['L0'] = null;
daqStatus['L1'] = null;
daqStatus['L2'] = null;
daqStatus['L3'] = null;
daqStatus['DT'] = null;
daqStatus['TI'] = null;
daqStatus['VL'] = null;
daqStatus['SA'] = null;
daqStatus['S0'] = null;
daqStatus['S1'] = null;
daqStatus['S2'] = null;
daqStatus['S3'] = null;
daqStatus['TG'] = null;
daqStatus['UP'] = null;

var months = [ "Jan", "Feb", "Mar", "Apr", "May", "Jun",
	       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" ];

function createXMLHttp() {
    var xmlHttp;
    try {
	// Firefox, Opera 8.0+, Safari
	xmlHttp=new XMLHttpRequest();
    } catch (e) {
	// Internet Explorer
	try {
	    xmlHttp=new ActiveXObject("Msxml2.XMLHTTP");
	} catch (e) {
	    try {
		xmlHttp=new ActiveXObject("Microsoft.XMLHTTP");
	    } catch (e) {
		alert("Your browser does not support AJAX!");
		return false;
	    }
	}
    }
    return xmlHttp;
}

function onLoad() {

    try {
	console.log("");
    } catch(e) {
	verbose = false;
    }

    if ( !hostname )
	hostname = window.location.hostname;

    var url = location.href;
    var temp = url.split("/");

    if ( temp[temp.length-1].indexOf("\.html") > -1 )
	temp[temp.length-1] = "";

    url = temp.join("/");

    var swffile = url + "jsocket.advanced.swf";

    // Create a new socket for use with the daq server
    cardSocket = new jSocket(cardReady,connectCard,putData,close);
    cardSocket.setup("card_socket",swffile);

    // get a pointer to the daq box
    var daqBox = document.getElementById('daqBox');
    
    // Flush the current contents
    if ( daqBox )
	daqBox.value = "";
    else
	return false;

    /*-- Now do the same for the chat box --*/
    chatSocket = new jSocket(chatReady,connectChat,chatter,close);
    chatSocket.setup("chat_socket", swffile);

    // get a pointer to the daq box
    var chatBox = document.getElementById('chatterBox');
    
    // Flush the current contents
    if ( chatBox )
	chatBox.value = "";
    else
	return false;

    return true;
}

function unLoad() {
    if ( cardSocket && cardSocket.connected ) {
	cardSocket.write("close\n");
	cardSocket.close();
    }

    if ( chatSocket && chatSocket.connected ) {
	chatSocket.write("close\n");
	chatSocket.close();
    }

    return false;
}

function cardReady() {
    verbose && console.log("card socket ready");
    cardSocket.connect(hostname, cardPort);
    return;
}

function chatReady() {
    verbose && console.log("chat socket ready");
    chatSocket.connect(hostname, chatPort);
    return;
}

/*------------------------------------------------------------*/
/*                    DAQ box functions                       */
/*------------------------------------------------------------*/
var command = new String();

function sendCommand( command ) {
    verbose && console.log("sending "+command);
    cardSocket.write(command+"\n");
    return;
}

function checkKey(event) {

    var code = event.keyCode;

    if ( code == 13 )
	handleInput(document.getElementById('daqBox'));
    else if ( code == 27 )
	resumeStream();
    else if ( code == 8 ) {
	command = command.chop();
	window.status = command;
    }
    else if ( code < 32 )
	return false;
    else if ( code == 188 ) {
	command += ',';
	window.status += ',';
    } else if ( code == 220 ) {
	command += '\\';
	window.status += '\\';
    } else {
	command += String.fromCharCode(code);
	window.status += String.fromCharCode(code);
    }

    return false;
}

function interuptStream() {
    typingFlag = true;
    return false;
}

function resumeStream() {
    typingFlag = false;
    command = "";
    return false;
}

function handleInput( daqBox ) {
    if ( !typingFlag )
	return false;

    if ( command.length < 2 )
	return false;

    sendCommand(command.toUpperCase());
    typingFlag = false;
    command = "";
    window.status = "";

    return false;
}

function closeSocket() {
    cardSocket.write("close\n");
    closeDown = true;
    return;
}

var accumulator = new String();
function putData(content) {
    var response = new String();
    response = cardSocket.readUTFBytes(content);

    // If the user is currently typing... 
    // don't keep pushing the output into the box
    if ( typingFlag ) {
	accumulator += response;
	return;
    }
    
    // If we have accumulated data... add it to the rsponse
    if ( accumulator.length > 0 ) {
	response = accumulator + response;
	accumulator = "";
    }

    // If there was, in fact, a response... deal with it here
    if ( response.length > 0 ) {

	if ( response.indexOf( "Please enter password" ) > -1 ) {
	    document.getElementById('block').style.display='block';
	    document.getElementById('pwd').focus();
	    return;

	} else if ( response.indexOf( "status|" ) > -1 ||
		    response.indexOf( "stat:" )    > -1 ) {

	    var searchString = new String();
	    if ( response.indexOf("stat:") > -1 )
		searchString = "stat:";
	    else
		searchString = "status|";

	    var lineArray = response.split('\n');
	    var status_line = new String();

	    for ( var i=0; i<lineArray.length-1; i++ ) {
		if ( lineArray[i].indexOf(searchString) > -1 ) {
		    status_line = lineArray[i];
		    lineArray.splice(i,1);
		    i--;
		}
	    }

	    if ( lineArray[lineArray.length-1].indexOf(searchString) > -1 ) {
		status_line = lineArray[lineArray.length-1];
		pop(lineArray);
	    }

	    status_line.chomp();

	    var start  = status_line.indexOf( searchString ) + 7;

	    status_line = status_line.substr(start);

	    // And schedule it to update in a few seconds
	    var callback = function() {make_status(status_line);};
	    setTimeout(callback,2500);

	    if ( lineArray.length < 2 )
		return;

	    for ( var i=0; i<lineArray.length; i++ ) {
		if ( lineArray[i].indexOf(searchString) > -1 ) {
		    splice(lineArray, i, 1);
		    i--;
		}
	    }

	    reponse = lineArray.join("\n");
	    while ( response.indexOf(searchString) > -1 ) {
		var start = response.indexOf(searchString);
		var length = response.indexOf('\n', start);
		response = response.substr(0,start-2) + response.substr(length);
	    }
	}

	verbose && console.log("socket data: "+content+" bytes read");

	var daqBox = document.getElementById('daqBox');

	// Toss the newlines in the response from the server
	response = response.replace(/\r/g,'');

	var lines = daqBox.value.split("\n");
	lines = lines.concat(response.split("\n"));

	if ( lines.length > maxLines ) {
	    lines = lines.slice(lines.length-maxLines);
	    response = lines.join("\n");

	    // Join sometimes doubles up the \n.
	    response = response.replace(/\n\n/g,'\n');

	    // Update the daqBox
	    daqBox.value = response;
	} else
	    daqBox.value += response;

    } // End if ( response )

    // Move the scroll bar down to the bottom
    daqBox.scrollTop = daqBox.scrollHeight;

    if ( closeDown )
	cardSocket.close();

    return false;
}

/*------------------------------------------------------------*/
/*                    Chat box functions                      */
/*------------------------------------------------------------*/
var chatTypingFlag = false;
function chatKey(event) {
    var code  = event.keyCode;
    var shift = event.shiftKey;

    if ( code == 13 )
	sendChat(document.getElementById('chatterBox'));
    else if ( code == 27 )
	resumeChat();

    return false;
}

function interuptChat() {
    chatTypingFlag = true;
    return false;
}

function resumeChat() {
    chatTypingFlag = false;
    return false;
}

function sendChat( chatBox ) {
    if ( !chatTypingFlag )
	return false;
    
    var temp = chatBox.value.split('\n');

    verbose && console.log("chat sending "+temp[temp.length-2]);
    chatSocket.write(temp[temp.length-2]+"\n");
    chatTypingFlag = false;
    return false;
}

var chatAccumulator = new String();
function chatter(content) {
    
    var response = new String();
    response = chatSocket.readUTFBytes(content);

    // If the user is currently typing... 
    // don't keep pushing the output into the box
    if ( chatTypingFlag ) {
	chatAccumulator += response; // But save it for later
	return;
    }

    // If there's a password... pop the password div
    if ( response.indexOf( "Please enter the password" ) > -1 ) {
	document.getElementById('block').style.display='block';
	document.getElementById('pwd').focus();
	return;
    }

    // If we have some save data.. add it to the response
    if ( chatAccumulator.length > 0 ) {
	response = chatAccumulator + response;
	chatAccumulator = "";
    }

    // Get a pointer to the chat box
    var chatBox = document.getElementById('chatterBox');

    // Toss the newlines in the response from the server
    response = response.replace(/\r/g,'');

    var lines = chatBox.value.split("\n");
    lines = lines.concat(response.split("\n"));

    if ( lines.length > maxLines ) {
	lines = lines.slice(lines.length-maxLines);
	response = lines.join("\n");

	// Join sometimes doubles up the \n.
	response = response.replace(/\n\n/g,'\n');

	// Update the chatBox
	chatBox.value = response;
    } else
	chatBox.value += response;

    // Move the scroll bar down to the bottom
    chatBox.scrollTop = chatBox.scrollHeight;

    if ( closeDown )
	chatSocket.close();

    return false;
}


/*------------------------------------------------------------*/
/*                 Logging functions                          */
/*------------------------------------------------------------*/
function close() {
    verbose && console.log("socket close");
    return;
}

function connectChat(success,error) {
    verbose && console.log("chat socket connected");
    if ( !success ) {
	verbose && console.log( "error:" + error );
	return;
    }

    document.getElementById('chatterBox').style.display = 'block';

    return;
}
function connectCard(success,error) {
    verbose && console.log("daq socket connected");
    if ( !success ) {
	verbose && console.log( "error:" + error );
	return;
    }

    // Show the element
    document.getElementById('daqBox').style.display = 'block';
 
    // And set the focus
    document.getElementById('daqBox').focus();

    // We want status lines from the server
    cardSocket.write("SS 1\n");

    return;
}
function connect(success,error) {
    verbose && console.log("daq socket connected");
    if ( !success ) {
	verbose && console.log( "error:" + error );
	return;
    }
    return;
}

function sendPwd(input) {
    var xmlHttp = createXMLHttp();
    var request = new String();
    var value = input.value;

    input.value = '';

    request = "test.pl?passwd="+value;

    xmlHttp.open("GET",request,false);
    xmlHttp.send(null);

    if ( xmlHttp.responseText.indexOf('success') > -1 ) {
	document.getElementById('block').style.display = 'none';
	cardSocket.write(value+"\n");
	chatSocket.write(value+"\n");
    } else
	window.location.href = '403.html';


    return;
}

var status_in_progress = false;
function make_status(status_line) {
    if ( status_in_progress ) {
	window.status = 'rescheduling status';
	var callback = function() {make_status(status_line);};
	setTimeout(callback, 10000);
    }

    status_in_progress = true;

    var stat = new Array();
    stat = status_line.split(',');

    for ( var i=0; i<stat.length; i++ ) {

	var temp = stat[i].split(/=/);
	var index = temp[0];
	var value = temp[1];

	daqStatus[index] = value;
    }

    if ( daqStatus['UP'] ) {
	daqStatus['UP'] = 1;
    }

    if ( daqStatus['SN'] ) {
	document.getElementById('serialNumber').innerHTML = 
	    "QuarkNet DAQ Card #" + daqStatus['SN'];
	daqStatus['SN'] = null;
    }

    if ( daqStatus['LT'] ) {
	var degrees = String.fromCharCode(176);

	var lat = daqStatus['LT'];
	var lng = daqStatus['LG'];
	var alt = daqStatus['AL'];

	var deg = lat.substr(0,lat.indexOf(':'));
	if ( deg.substr(0,1) == '0' ) 
	    deg = deg.substr(1, deg.length);
	var min = lat.substring(lat.indexOf(":")+1,lat.indexOf("."));
	min = Math.round(min);
	var dir = lat.substr(lat.length-1);

	lat = deg + degrees + min + "'" + dir;

	deg = lng.substr(0,lng.indexOf(':'));
	if ( deg.substr(0,1) == '0' ) 
	    deg = deg.substr(1, deg.length);
	min = lng.substring(lng.indexOf(":")+1,lng.indexOf("."));
	min = Math.round(min);
	dir = lng.substr(lng.length-1);
	
	lng = deg + degrees + min + "'" + dir;
		
	var height = alt.substr(0,alt.length-2);
	height = Math.round(height);
	var units  = alt.substr(alt.length-2);

	alt = height.toString() + units;

	document.getElementById('location').innerHTML =
	    lat + ' ' + lng + ' ' + alt;

	daqStatus['LT'] = daqStatus['LG'] = daqStatus['AL'] = null;
    }

    if ( daqStatus['C0'] ) {
	var coIncidenceStr = new String();

	var cLevel  = parseInt( daqStatus['C0'].substr(0,1) ) + 1;
	var paddles = parseInt( "0x"+daqStatus['C0'].substr(1,1));
	    
	coIncidenceStr = 
	    cLevel + '-fold coincidence on channels ';

	for ( var i=0; i<4; i++ ) {
	    var mask = 1<<i;
	    var bitIsSet = (paddles & mask) != 0
		if ( bitIsSet )
		    coIncidenceStr += i + ", ";
	}
	coIncidenceStr = 
	    coIncidenceStr.substr(0,coIncidenceStr.length-2);

	document.getElementById('coincidence').innerHTML =
	    coIncidenceStr;

	if ( daqStatus['UP'] ) {
	    document.getElementById('coincidence').style.color = 'red';
	    daqStatus['UP'] = 0;
	}
	daqStatus['C0'] = null;
    }

    if ( daqStatus['S0'] ) {
	var counters = new String();
	
	counters = "Counters: ch0=" + daqStatus['S0'] + " ch1=" + 
	    daqStatus['S1'] + " ch2=" + daqStatus['S2'] + " ch3=" + 
	    daqStatus['S3'] + "<BR>triggers = " + daqStatus['TG'];

	daqStatus['S0'] = daqStatus['S1'] = 
	    daqStatus['S2'] = daqStatus['S3'] = null;

	document.getElementById('counters').innerHTML = counters;
    }

    if ( daqStatus['L0'] && daqStatus['L1'] &&
	 daqStatus['L2'] && daqStatus['L3'] ) {
	var thresholds = new String();
	thresholds = 
	    'Thresholds (mV) L0=' + daqStatus['L0']	+ ' L1=' + 
	    daqStatus['L1'] + ' L2=' + daqStatus['L2'] + 
	    ' L3=' + daqStatus['L3'];

	document.getElementById('thresholds').innerHTML = thresholds;

	daqStatus['L0'] = daqStatus['L1'] = 
	    daqStatus['L2'] = daqStatus['L3'] = null;
    } 

    if ( daqStatus['L0'] && daqStatus['UP'] ) {
	var thresh = document.getElementById('thresholds').innerHTML;

	var l0 = thresh.match(/L0=(\d+)/)[0];
	var l  = new String("L0="+daqStatus['L0']);

	thresh = thresh.replace(l0, l);
	document.getElementById('thresholds').innerHTML = thresh;

	document.getElementById('thresholds').style.color = 'red';
	daqStatus['UP'] = 0;
	daqStatus['L0'] = null;

    } else if ( daqStatus['L1'] && daqStatus['UP'] ) {
	var thresh = document.getElementById('thresholds').innerHTML;

	var l1 = thresh.match(/L1=(\d+)/)[0];
	var l  = new String("L1="+daqStatus['L1']);

	thresh = thresh.replace(l1, l);
	document.getElementById('thresholds').innerHTML = thresh;

	document.getElementById('thresholds').style.color = 'red';
	daqStatus['UP'] = 0;
	daqStatus['L1'] = null;

    } else if ( daqStatus['L2'] && daqStatus['UP'] ) {
	var thresh = document.getElementById('thresholds').innerHTML;

	var l2 = thresh.match(/L2=(\d+)/)[0];
	var l  = new String("L2="+daqStatus['L2']);

	thresh = thresh.replace(l2, l);
	document.getElementById('thresholds').innerHTML = thresh;

	document.getElementById('thresholds').style.color = 'red';
	daqStatus['UP'] = 0;
	daqStatus['L2'] = null;

    } else if ( daqStatus['L3'] && daqStatus['UP'] ) {
	var thresh = document.getElementById('thresholds').innerHTML;

	var l3 = thresh.match(/L3=(\d+)/)[0];
	var l  = new String("L3="+daqStatus['L3']);

	thresh = thresh.replace(l3, l);
	document.getElementById('thresholds').innerHTML = thresh;

	document.getElementById('thresholds').style.color = 'red';
	daqStatus['UP'] = 0;
	daqStatus['L3'] = null;

    }

    if ( daqStatus['DT'] ) {
	var datetimegps = new String();
	
	var day    = daqStatus['DT'].substr(0,2);
	var nmonth = parseInt(daqStatus['DT'].substr(2,2)) - 1;
	var month  = months[nmonth];
	var year   = parseInt(daqStatus['DT'].substr(4,2));
	var date   = day + ' ' + month + ' ' + year;

	var time   = daqStatus['TI'].substr(0,2) + ':' +
	    daqStatus['TI'].substr(2,2) + ':' +
	    daqStatus['TI'].substr(4,2) + ' UTC&nbsp;&nbsp;';

	datetimegps = 
	    date + ' ' + time + 'GPS Status: ' + daqStatus['VL'] + ' ' 
	    + daqStatus['SA'] + ' Sats';
	document.getElementById('datetimegps').innerHTML = datetimegps;

	daqStatus['DT'] = null;
    }

    if ( daqStatus['LK'] ) {
	// Update the lock status
	isLocked = (daqStatus['LK'] != 0) ? true : false;

	try {
	    var lockitBTN  = document.getElementById('lock');
	    var releaseBTN = document.getElementById('release');

	    if ( isLocked ) {
		crilLocked = true;
		if ( getCookie("hasLock") ) {
		    releaseBTN.style.display = 'block';
		    lockitBTN.style.display  = 'none';
		} else {
		    releaseBTN.style.display = 'none';
		    lockitBTN.style.display = 'block';
		    lockitBTN.value = 'CRiL Locked';
		    lockitBTN.disabled = true;
		}
	    } else {
		crilLocked = false;
		releaseBTN.style.display = 'none';
		lockitBTN.style.display  = 'block';
		lockitBTN.value = 'Lock CRiL';
		lockitBTN.disabled = false;
	    }
	} catch(e) {}

	daqStatus['LK'] = null;
    }

    // And the motor position
    if ( daqStatus['MT'] ) {
	try {
	    document.getElementById('displayPosition').innerHTML = 
		"The CRiL is " + daqStatus['MT'];
	} catch(e) {}

	daqStatus['MT'] = null;
    }

    status_in_progress = false;
    return false;
}
