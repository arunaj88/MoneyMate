package com.example.money_mate

import androidx.core.content.FileProvider

/** Serves shared loan statements; its own class so it never clashes with
 *  the file providers that plugins declare. */
class StatementFileProvider : FileProvider()
