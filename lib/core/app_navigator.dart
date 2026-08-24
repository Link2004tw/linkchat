import 'package:flutter/material.dart';

/// App-global navigator key, attached to MaterialApp so routes can be pushed
/// from outside the widget tree (push notifications, deep-link auth hand-off).
final GlobalKey<NavigatorState> appNavigatorKey =
    GlobalKey<NavigatorState>();