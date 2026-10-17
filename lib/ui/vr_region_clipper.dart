import 'package:flutter/material.dart';

class VrRegionClipper extends CustomClipper<Path> {
  const VrRegionClipper(this.path);
  final Path path;
  @override
  Path getClip(Size size) => path;
  @override
  bool shouldReclip(VrRegionClipper oldClipper) =>
      !identical(path, oldClipper.path);
}
