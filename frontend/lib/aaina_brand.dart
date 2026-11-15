import 'package:flutter/material.dart';

class AainaWordmark extends StatelessWidget {
  final double width;

  const AainaWordmark({super.key, this.width = 88});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: Image.asset(
      'assets/branding/aaina_logo.png',
      width: width,
      height: width * 0.27,
      fit: BoxFit.cover,
      semanticLabel: 'aaina',
    ),
  );
}
