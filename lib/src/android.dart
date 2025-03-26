import 'dart:typed_data';
import 'dart:async';

import 'package:usb_serial/usb_serial.dart';

import 'package:libserialport/src/port.dart';
import 'package:libserialport/src/enums.dart';
import 'package:libserialport/src/config.dart';
import 'package:libserialport/src/error.dart';

/// Serial port Android implementation.
class SerialPortAndroid implements SerialPort {
  late UsbDevice _device;
  UsbPort? port;
  bool _portOpened = false;
  Uint8List dataAvailable = Uint8List(0);
  StreamSubscription? _reading;

  static List<UsbDevice> _currentDevices = [];

  SerialPortAndroid(String listIdx) {
    List<String> splittedIdx = listIdx.split("+");

    int idx = int.parse(splittedIdx[0]);

    if (splittedIdx.length == 2) {
      interfaceNumber = int.parse(splittedIdx[1]);
    }

    if ((idx < _currentDevices.length) && (idx >= 0)) {
      _device = _currentDevices[idx];
    }
  }

  SerialPortAndroid.fromAddress(int address) {
    for (UsbDevice device in _currentDevices) {
      if (address == device.deviceId) _device = device;
    }
  }

  @override
  int get address => (_device != null) ? _device!.deviceId! : 0;

  /// Lists the serial ports available on the system.
  static Future<List<String>> get availablePorts async {
    _currentDevices = await UsbSerial.listDevices();
    List<String> devices = [];

    for (var i = 0; i < _currentDevices.length; i++) {
      int? intCount = _currentDevices[i].interfaceCount;

      //usb_serial doesn't seem to list different serial port from a single usb device, this is a work around.
      if ((intCount != null) && (intCount! > 1)) {
        for (var j = 0; j < intCount!; j++) {
          //Add the device number to the list.
          devices.add(i.toString() + "+" + j.toString());
        }
      } else {
        devices.add(i.toString() + "+-1");
      }
    }

    return devices;
  }

  /// Releases all resources associated with the serial port.
  ///
  /// @note Call this function after you're done with the serial port.
  void dispose() {
    close();
  }

  /// Opens the serial port in the specified `mode`.
  ///
  /// See also:
  /// - [SerialPortMode]
  Future<bool> open({required int mode}) async {
    UsbPort? p = await _device.create("", interfaceNumber);

    if (p == null) {
      return false;
    }

    port = p!;

    _portOpened = await port!.open();

    //If port is open, start reading, to start filling the buffer, so the user can check if there is already data available
    if(_portOpened) _startReading();

    return _portOpened;
  }

  void _startReading() {
    if (_reading != null) return;

    //Clear data
    dataAvailable = Uint8List(0);

    //Start listening for data
    if (port!.inputStream != null) {
      _reading = port!.inputStream!.listen((Uint8List data) {
        var b = BytesBuilder();
        b.add(dataAvailable);
        b.add(data);
        dataAvailable = b.toBytes();
      });
    }
  }

  /// Opens the serial port for reading only.
  Future<bool> openRead() => open(mode: 0);

  /// Opens the serial port for writing only.
  Future<bool> openWrite() => open(mode: 0);

  /// Opens the serial port for reading and writing.
  Future<bool> openReadWrite() => open(mode: 0);

  /// Closes the serial port.
  Future<bool> close() async {
    if (_reading != null) {
      _reading!.cancel();
      _reading = null;
    }

    if (isOpen && (port != null)) {
      bool result = await port!.close();
      _portOpened = !result;
      return result;
    }

    return false;
  }

  /// Gets whether the serial port is open.
  bool get isOpen => _portOpened;

  /// Gets the name of the port.
  ///
  /// The name returned is whatever is normally used to refer to a port on the
  /// current operating system; e.g. for Windows it will usually be a "COMn"
  /// device name, and for Unix it will be a device path beginning with "/dev/".
  String? get name => _device.deviceName;

  /// Gets the description of the port, for presenting to end users.
  String? get description => "";

  /// Gets the transport type used by the port.
  ///
  /// See also:
  /// - [SerialPortTransport]
  int get transport => SerialPortTransport.usb;

  /// Gets the USB bus number of a USB serial adapter port.
  int? get busNumber => -1;

  /// Gets the USB device number of a USB serial adapter port.
  int? get deviceNumber => _device.deviceId;

  /// Gets the USB vendor ID of a USB serial adapter port.
  int? get vendorId => _device.vid;

  /// Gets the USB Product ID of a USB serial adapter port.
  int? get productId => _device.pid;

  /// Gets the USB interface number.
  int _interfaceNumber = -1;

  int get interfaceNumber => _interfaceNumber;

  set interfaceNumber(int val) {
    _interfaceNumber = val;
  }

  int? get interfaceCount => _device.interfaceCount;

  /// Get the USB manufacturer of a USB serial adapter port.
  String? get manufacturer => _device.manufacturerName;

  /// Gets the USB product name of a USB serial adapter port.
  String? get productName => _device.productName;

  /// Gets the USB serial number of a USB serial adapter port.
  String? get serialNumber => _device.serial;

  /// Gets the MAC address of a Bluetooth serial adapter port.
  String? get macAddress => serialNumber;

  SerialPortConfig? _config;

  /// Gets the current configuration of the serial port.
  SerialPortConfig get config => _config!;

  /// Sets the configuration for the serial port.
  ///
  /// For each parameter in the configuration, there is a special value
  /// (usually -1, but see the documentation for each field). These values
  /// will be ignored and the corresponding setting left unchanged on the port.
  ///
  /// Upon errors, the configuration of the serial port is unknown since
  /// partial/incomplete config updates may have happened.
  Future<void> setConfig(SerialPortConfig config) async {
    _config = config;

    //Configure port
    await port!.setDTR((config.dtr == SerialPortDtr.on));
    await port!.setFlowControl(config.flowControl);
    await port!.setPortParameters(config.baudRate, config.bits, config.stopBits, config.parity);
    await port!.setRTS((config.rts == SerialPortRts.on));
  }

  /// Read data from the serial port.
  ///
  /// The operation attempts to read N `bytes` of data.
  ///
  /// If `timeout` is 0 or greater, the read operation is blocking.
  /// The timeout is specified in milliseconds. Pass 0 to wait infinitely.
  Future<Uint8List> read(int bytes, {int timeout = -1}) async {
    _startReading();

    if (dataAvailable.length >= bytes) {
      Uint8List subData = dataAvailable.sublist(0, bytes);
      dataAvailable = dataAvailable.sublist(bytes, dataAvailable.length);
      return subData;
    } else if (timeout != -1) {
      int elapsedTime = 0;
      do {
        await Future.delayed(const Duration(milliseconds: 1));
        elapsedTime++;

        if (dataAvailable.length >= bytes) {
          Uint8List subData = dataAvailable.sublist(0, bytes);
          dataAvailable = dataAvailable.sublist(bytes, dataAvailable.length);
          return subData;
        }
      } while (elapsedTime < timeout);
    }

    return Uint8List(0);
  }

  /// Write data to the serial port.
  ///
  /// If `timeout` is 0 or greater, the write operation is blocking.
  /// The timeout is specified in milliseconds. Pass 0 to wait infinitely.
  ///
  /// Returns the amount of bytes written.
  Future<int> write(Uint8List bytes, {int timeout = -1}) async {
    if (port != null) {
      await port!.write(bytes);
      return bytes.length;
    }

    return -1;
  }

  /// Gets the amount of bytes available for reading.
  int get bytesAvailable => dataAvailable.length;

  /// Gets the amount of bytes waiting to be written.
  int get bytesToWrite => 0;

  /// Flushes serial port buffers. Data in the selected buffer(s) is discarded.
  ///
  /// See also:
  /// - [SerialPortBuffer]
  void flush([int buffers = SerialPortBuffer.both]) {
    //Not available
  }

  /// Waits for buffered data to be transmitted.
  void drain() {
    //Not available
  }

  /// Gets the status of the control signals for the serial port.
  int get signals => 0;

  /// Puts the port transmit line into the break state.
  bool startBreak() {
    //Not available
    return false;
  }

  /// Takes the port transmit line out of the break state.
  bool endBreak() {
    //Not available
    return false;
  }

  /// Gets the error for a failed operation.
  static SerialPortError? _err;
  static SerialPortError? get lastError => _err;
}

/// Serial port config for Android.
class SerialPortConfigAndroid implements SerialPortConfig {
  SerialPortConfigAndroid() {}

  /// @internal
  factory SerialPortConfigAndroid.fromAddress(int address) {
    SerialPortConfigAndroid conf = SerialPortConfigAndroid();
    conf.address = address;
    return conf;
  }

  /// @internal
  int address = 0;

  /// Releases all resources associated with the serial port config.
  ///
  /// @note Call this function after you're done with the serial port config.
  void dispose() {}

  /// Gets the baud rate from the port configuration.
  int baudRate = 0;

  /// Gets the data bits from the port configuration.
  int bits = 0;

  /// Gets the parity setting from the port configuration.
  int _parity = 0;
  int get parity => _parity;

  /// Sets the parity setting in the port configuration.
  set parity(int value) {
    switch (value) {
      case SerialPortParity.invalid:
        _parity = -1;
        break;
      case SerialPortParity.none:
        _parity = UsbPort.PARITY_NONE;
        break;
      case SerialPortParity.odd:
        _parity = UsbPort.PARITY_ODD;
        break;
      case SerialPortParity.even:
        _parity = UsbPort.PARITY_EVEN;
        break;
      case SerialPortParity.mark:
        _parity = UsbPort.PARITY_MARK;
        break;
      case SerialPortParity.space:
        _parity = UsbPort.PARITY_SPACE;
        break;
    }
  }

  /// Gets the stop bits from the port configuration.
  int stopBits = 0;

  /// Gets the RTS pin behaviour from the port configuration.
  ///
  /// See also:
  /// - [SerialPortRts]
  int rts = 0;

  /// Gets the CTS pin behaviour from the port configuration.
  ///
  /// See also:
  /// - [SerialPortCts]
  int cts = 0;

  /// Gets the DTR pin behaviour from the port configuration.
  ///
  /// See also:
  /// - [SerialPortDtr]
  int dtr = 0;

  /// Gets the DSR pin behaviour from the port configuration.
  ///
  /// See also:
  /// - [SerialPortDsr]
  int dsr = 0;

  /// Gets the XON/XOFF configuration from the port configuration.
  ///
  /// See also:
  /// - [SerialPortXonXoff]
  int xonXoff = 0;

  /// Sets the flow control type in the port configuration.
  ///
  /// This function is a wrapper that sets the RTS, CTS, DTR, DSR and
  /// XON/XOFF settings as necessary for the specified flow control
  /// type. For more fine-grained control of these settings, use their
  /// individual configuration functions.
  ///
  /// See also:
  /// - [SerialPortFlowControl]
  int _flowControl = 0;

  void setFlowControl(int value) {
    switch (value) {
      case SerialPortFlowControl.none:
        _flowControl = UsbPort.FLOW_CONTROL_OFF;
        break;
      case SerialPortFlowControl.xonXoff:
        _flowControl = UsbPort.FLOW_CONTROL_XON_XOFF;
        break;
      case SerialPortFlowControl.rtsCts:
        _flowControl = UsbPort.FLOW_CONTROL_RTS_CTS;
        break;
      case SerialPortFlowControl.dtrDsr:
        _flowControl = UsbPort.FLOW_CONTROL_DSR_DTR;
        break;
      default:
        _flowControl = UsbPort.FLOW_CONTROL_OFF;
    }
  }

  int get flowControl => _flowControl;
}
