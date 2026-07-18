// Copyright (c) 2026 LG Electronics, Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#include <flutter_window.h>

#include "flutter/generated_plugin_registrant.h"

class App : public FlutterWindow {
 public:
  bool OnCreate() override {
    if (!FlutterWindow::OnCreate()) return false;
    RegisterPlugins(GetRegistrar());
    return true;
  }
};

int main(int argc, char** argv) {
  App app;
  return app.Run(argc, argv);
}
