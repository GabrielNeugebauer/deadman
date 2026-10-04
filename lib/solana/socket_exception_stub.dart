/// Stands in for dart:io's SocketException on the web, where network
/// failures surface as http's ClientException instead.
class SocketException implements Exception {}
