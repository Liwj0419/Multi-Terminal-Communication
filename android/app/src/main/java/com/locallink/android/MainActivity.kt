package com.locallink.android

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

private enum class AndroidPanel {
  Messages,
  Pictures,
  Files
}

class MainActivity : Activity() {
  private lateinit var manager: LocalLinkManager
  private lateinit var content: LinearLayout
  private var selectedPeerID: String? = null
  private var showingSettings = false
  private var selectedPanel: AndroidPanel = AndroidPanel.Messages
  private val pickPictureCode = 1001
  private val pickFileCode = 1002

  private val blue = Color.rgb(22, 64, 143)
  private val blueSoft = Color.rgb(232, 239, 255)
  private val green = Color.rgb(16, 130, 93)
  private val red = Color.rgb(185, 55, 65)
  private val ink = Color.rgb(28, 32, 38)
  private val muted = Color.rgb(100, 110, 124)
  private val line = Color.rgb(224, 228, 236)
  private val page = Color.rgb(247, 248, 251)
  private val surface = Color.WHITE

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    window.statusBarColor = page
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
    }

    manager = LocalLinkManager(this)
    manager.onChanged = { render() }
    manager.onError = { Toast.makeText(this, it, Toast.LENGTH_LONG).show() }
    manager.onPairRequest = { identity, code -> showPairRequest(identity, code) }

    content = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(dp(18), statusBarHeight() + dp(14), dp(18), dp(28))
    }
    val scrollView = ScrollView(this).apply {
      setBackgroundColor(page)
      isFillViewport = true
      addView(
        content,
        ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
      )
    }
    setContentView(scrollView)
    manager.start()
    render()
  }

  override fun onDestroy() {
    manager.stop()
    super.onDestroy()
  }

  @Deprecated("Deprecated in Java")
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    if (resultCode != RESULT_OK) return
    val uri = data?.data ?: return
    val peer = selectedPeer() ?: return
    val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return
    val name = displayName(uri) ?: if (requestCode == pickPictureCode) "Photo.jpg" else "File"
    val type = contentResolver.getType(uri)
    manager.sendData(peer, bytes, name, type)
  }

  private fun render() {
    content.removeAllViews()
    if (showingSettings) {
      renderSettingsPage()
    } else {
      selectedPeer()?.let { renderDetailPage(it) } ?: renderDeviceListPage()
    }
  }

  private fun renderDeviceListPage() {
    renderTitleBar("LocalLink", showBack = false, showControls = true)
    renderNearby()
    renderTrusted()
  }

  private fun renderDetailPage(peer: DiscoveredPeer) {
    renderTitleBar(peer.identity.displayName, showBack = true, showControls = false)
    renderPeerStatus(peer)
    renderTabs()
    val connected = manager.connectedPeerIDs.contains(peer.identity.deviceID)
    when (selectedPanel) {
      AndroidPanel.Messages -> renderMessages(peer, connected)
      AndroidPanel.Pictures -> renderTransfers(peer, pictures = true)
      AndroidPanel.Files -> renderTransfers(peer, pictures = false)
    }
    renderComposer(peer, connected)
  }

  private fun renderSettingsPage() {
    renderTitleBar("Settings", showBack = true, showControls = false)
    content.addView(
      card().apply {
        addView(label("This Device", ink, 16f, true))
        val nameInput = EditText(this@MainActivity).apply {
          setText(manager.local.identity.displayName)
          hint = "Device name"
          textSize = 16f
          setSingleLine(true)
          inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_WORDS
          setPadding(dp(14), dp(8), dp(14), dp(8))
          background = rounded(Color.rgb(246, 248, 252), dp(12), line)
        }
        addView(settingRow("Name", nameInput, primaryButton("Save", true) {
            manager.updateDeviceName(nameInput.text.toString())
            Toast.makeText(this@MainActivity, "Device name saved", Toast.LENGTH_SHORT).show()
          }), blockParams(top = dp(10)))
        addView(label("ID ${manager.local.identity.deviceID.take(8)}", muted, 13f, false), blockParams(top = dp(8)))
      }
    )

    content.addView(sectionTitle("Connection"))
    content.addView(
      card().apply {
        val addresses = manager.connectionAddresses()
        val addressText = label(
          if (addresses.isEmpty()) "Start LocalLink to show this device address." else addresses.first(),
          muted,
          13f,
          false
        ).apply {
          typeface = Typeface.MONOSPACE
        }
        val copyButton = addresses.firstOrNull()?.let { address ->
          actionButton("Copy", true) {
            copyText(address)
            Toast.makeText(this@MainActivity, "Address copied", Toast.LENGTH_SHORT).show()
          }
        }
        addView(settingRow("This device", addressText, copyButton))
        val endpointInput = EditText(this@MainActivity).apply {
          hint = "192.168.1.20:53317"
          textSize = 16f
          setSingleLine(true)
          inputType = InputType.TYPE_CLASS_TEXT
          setPadding(dp(14), dp(8), dp(14), dp(8))
          background = rounded(Color.rgb(246, 248, 252), dp(12), line)
        }
        addView(settingRow("Manual", endpointInput, primaryButton("Connect", true) {
            manager.connectManually(endpointInput.text.toString())
            showingSettings = false
            render()
          }), blockParams(top = dp(10)))
      }
    )

    content.addView(sectionTitle("Trusted Devices"))
    val trusted = manager.trustedIdentities()
    if (trusted.isEmpty()) {
      content.addView(emptyCard("No paired devices"))
    } else {
      trusted.forEach { trustedPeer ->
        content.addView(
          card().apply {
            addView(label(trustedPeer.displayName, ink, 16f, true))
            addView(label("${trustedPeer.platform}  ${trustedPeer.deviceID.take(8)}", muted, 13f, false))
            if (!trustedPeer.lastHost.isNullOrBlank() && trustedPeer.lastPort > 0) {
              addView(label("Last endpoint ${trustedPeer.lastHost}:${trustedPeer.lastPort}", muted, 12f, false))
            }
            val actions = LinearLayout(this@MainActivity).apply {
              orientation = LinearLayout.HORIZONTAL
              setPadding(0, dp(10), 0, 0)
            }
            actions.addView(actionButton("Clear Messages", true) { manager.clearMessages(trustedPeer.deviceID) })
            actions.addView(actionButton("Clear Transfers", true) { manager.clearTransfers(trustedPeer.deviceID) })
            actions.addView(actionButton("Forget", true, danger = true) { manager.forget(trustedPeer.deviceID) })
            addView(actions)
          }
        )
      }
    }
  }

  private fun renderTitleBar(title: String, showBack: Boolean, showControls: Boolean) {
    val row = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    if (showBack) {
      row.addView(
        Button(this).apply {
          text = "‹"
          textSize = 28f
          setTextColor(blue)
          background = rounded(Color.TRANSPARENT, dp(10))
          setOnClickListener {
            if (showingSettings) {
              showingSettings = false
            } else {
              selectedPeerID = null
            }
            selectedPanel = AndroidPanel.Messages
            render()
          }
        },
        LinearLayout.LayoutParams(dp(52), dp(52)).apply { setMargins(0, 0, dp(6), 0) }
      )
    }
    row.addView(
      TextView(this).apply {
        text = title
        textSize = if (showBack) 22f else 30f
        typeface = Typeface.DEFAULT_BOLD
        setTextColor(ink)
        maxLines = 1
      },
      LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
    )
    if (showControls) {
      row.addView(
        iconButton(if (manager.isRunning) "Ⅱ" else "▶") {
          if (manager.isRunning) manager.stop() else manager.start()
        },
        LinearLayout.LayoutParams(dp(48), dp(48)).apply { setMargins(dp(8), 0, 0, 0) }
      )
      row.addView(
        iconButton("⚙") {
          showingSettings = true
          selectedPeerID = null
          render()
        },
        LinearLayout.LayoutParams(dp(48), dp(48)).apply { setMargins(dp(8), 0, 0, 0) }
      )
    }
    content.addView(row)
  }

  private fun renderNearby() {
    content.addView(sectionTitle("Nearby"))
    if (manager.peers.isEmpty()) {
      content.addView(emptyCard("No devices found on this Wi-Fi."))
      return
    }

    manager.peers.forEach { peer ->
      content.addView(peerRow(peer).apply {
        setOnClickListener {
          selectedPeerID = peer.identity.deviceID
          selectedPanel = AndroidPanel.Messages
          render()
        }
      })
    }
  }

  private fun renderTrusted() {
    content.addView(sectionTitle("Trusted"))
    val trusted = manager.trustedIdentities()
    if (trusted.isEmpty()) {
      content.addView(emptyCard("No paired devices"))
      return
    }
    trusted.forEach { trustedPeer ->
      val peer = peerFor(trustedPeer)
      content.addView(peerRow(peer).apply {
        setOnClickListener {
          selectedPeerID = trustedPeer.deviceID
          selectedPanel = AndroidPanel.Messages
          render()
        }
      })
    }
  }

  private fun peerRow(peer: DiscoveredPeer): View {
    val connected = manager.connectedPeerIDs.contains(peer.identity.deviceID)
    val row = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      setPadding(dp(14), dp(12), dp(12), dp(12))
      background = rounded(surface, dp(12), line)
      isClickable = true
      isFocusable = true
      layoutParams = blockParams(bottom = dp(8))
    }
    row.addView(
      TextView(this).apply {
        text = platformIcon(peer.identity.platform)
        textSize = 22f
        gravity = Gravity.CENTER
        setTextColor(muted)
      },
      LinearLayout.LayoutParams(dp(34), dp(44)).apply { setMargins(0, 0, dp(10), 0) }
    )
    val textColumn = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    textColumn.addView(label(peer.identity.displayName, ink, 16f, false))
    textColumn.addView(label(if (peer.trusted) "Paired" else peer.host.ifBlank { "Offline" }, muted, 12f, false))
    row.addView(textColumn, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
    row.addView(
      chip(
        if (connected) "Connected" else if (peer.trusted) "Paired" else "Nearby",
        if (connected) green else muted,
        if (connected) Color.rgb(226, 247, 239) else Color.rgb(242, 244, 248)
      )
    )
    return row
  }

  private fun renderPeerStatus(peer: DiscoveredPeer) {
    val connected = manager.connectedPeerIDs.contains(peer.identity.deviceID)
    content.addView(
      card().apply {
        val titleRow = LinearLayout(this@MainActivity).apply {
          orientation = LinearLayout.HORIZONTAL
          gravity = Gravity.CENTER_VERTICAL
        }
        titleRow.addView(
          TextView(this@MainActivity).apply {
            text = peer.identity.displayName
            textSize = 16f
            setTextColor(ink)
          },
          LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )
        titleRow.addView(
          chip(
            if (peer.trusted) {
              if (connected) "Connected" else "Paired"
            } else {
              "Not paired"
            },
            if (peer.trusted) green else muted,
            if (peer.trusted) Color.rgb(226, 247, 239) else Color.rgb(242, 244, 248)
          )
        )
        addView(titleRow)

        if (!peer.trusted) {
          addView(
            primaryButton("Pair", true) { manager.pair(peer) },
            blockParams(top = dp(12))
          )
        } else if (connected) {
          addView(
            actionButton("Disconnect", true, danger = true) { manager.disconnect(peer.identity.deviceID) },
            blockParams(top = dp(10))
          )
        } else {
          addView(
            primaryButton("Connect", peer.host.isNotBlank() && peer.port > 0) { manager.connect(peer) },
            blockParams(top = dp(12))
          )
        }
      }
    )
  }

  private fun renderTabs() {
    val tabs = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      background = rounded(Color.rgb(235, 238, 244), dp(12))
      setPadding(dp(3), dp(3), dp(3), dp(3))
    }
    AndroidPanel.entries.forEach { panel ->
      tabs.addView(
        Button(this).apply {
          text = panel.name
          textSize = 13f
          isAllCaps = false
          setTextColor(if (selectedPanel == panel) blue else muted)
          background = rounded(if (selectedPanel == panel) Color.WHITE else Color.TRANSPARENT, dp(10))
          setOnClickListener {
            selectedPanel = panel
            render()
          }
        },
        LinearLayout.LayoutParams(0, dp(42), 1f).apply {
          setMargins(dp(2), 0, dp(2), 0)
        }
      )
    }
    content.addView(tabs, blockParams(top = dp(2), bottom = dp(12)))
  }

  private fun renderMessages(peer: DiscoveredPeer, connected: Boolean) {
    val panel = card()
    panel.addView(label("Messages", ink, 16f, true))
    val peerMessages = manager.messages.filter { it.peerID == peer.identity.deviceID }.takeLast(40)
    if (peerMessages.isEmpty()) {
      panel.addView(label("No messages", muted, 15f, false), blockParams(top = dp(8)))
    } else {
      peerMessages.forEach { panel.addView(messageBubble(peer, it)) }
    }
    content.addView(panel)
  }

  private fun renderComposer(peer: DiscoveredPeer, connected: Boolean) {
    val panel = card()
    val input = EditText(this).apply {
      hint = "Send text"
      textSize = 16f
      minLines = 1
      maxLines = 4
      inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
      setPadding(dp(14), dp(8), dp(14), dp(8))
      background = rounded(Color.rgb(246, 248, 252), dp(12), line)
    }
    panel.addView(input, blockParams(top = dp(14)))
    val sendRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
    sendRow.addView(actionButton("Photo", connected) { pick("picture", "image/*", pickPictureCode) })
    sendRow.addView(actionButton("File", connected) { pick("file", "*/*", pickFileCode) })
    sendRow.addView(
      primaryButton("Send", connected) {
        manager.sendText(peer, input.text.toString())
        input.setText("")
      },
      LinearLayout.LayoutParams(0, dp(42), 1f)
    )
    panel.addView(sendRow, blockParams(top = dp(10)))
    content.addView(panel)
  }

  private fun renderTransfers(peer: DiscoveredPeer, pictures: Boolean) {
    val title = if (pictures) "Pictures" else "Files"
    val items = manager.transfers.filter { it.peerID == peer.identity.deviceID && it.isPicture == pictures }
    val panel = card()
    panel.addView(label(title, ink, 18f, true))
    if (items.isEmpty()) {
      panel.addView(label(if (pictures) "No pictures" else "No files", muted, 15f, false), blockParams(top = dp(8)))
    } else {
      items.forEach { panel.addView(transferRow(it)) }
    }
    content.addView(panel)
  }

  private fun messageBubble(peer: DiscoveredPeer, message: MessageItem): View {
    val wrapper = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = if (message.outgoing) Gravity.END else Gravity.START
    }
    wrapper.addView(
      TextView(this).apply {
        text = if (message.outgoing) "Me" else peer.identity.displayName
        textSize = 11f
        setTextColor(muted)
      }
    )
    wrapper.addView(
      TextView(this).apply {
        text = message.text
        textSize = 15f
        setTextColor(if (message.outgoing) Color.WHITE else ink)
        setPadding(dp(12), dp(8), dp(12), dp(8))
        background = rounded(if (message.outgoing) blue else Color.rgb(241, 244, 249), dp(14))
      },
      LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        setMargins(0, dp(2), 0, dp(10))
      }
    )
    return wrapper
  }

  private fun transferRow(item: TransferItem): View {
    val row = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(0, dp(12), 0, dp(12))
      showDivider()
    }
    val top = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    top.addView(
      TextView(this).apply {
        text = item.fileName
        textSize = 15f
        typeface = Typeface.DEFAULT_BOLD
        setTextColor(ink)
        maxLines = 1
      },
      LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
    )
    top.addView(chip(if (item.outgoing) "Sent" else "Received", blue))
    row.addView(top)
    row.addView(label("${formatBytes(item.completedBytes)} / ${formatBytes(item.totalBytes)}", muted, 13f, false))

    val actions = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      setPadding(0, dp(8), 0, 0)
    }
    if (item.isPicture) {
      actions.addView(actionButton("View", true) { viewPicture(item) })
    }
    actions.addView(actionButton(if (item.downloaded) "Downloaded" else "Download", !item.downloaded && item.complete) { download(item) })
    row.addView(actions)
    return row
  }

  private fun showPairRequest(identity: DeviceIdentity, code: String) {
    AlertDialog.Builder(this)
      .setTitle("Pair with ${identity.displayName}")
      .setMessage("Code: $code")
      .setNegativeButton("Reject", null)
      .setPositiveButton("Accept") { _, _ -> manager.acceptPair(identity) }
      .show()
  }

  private fun pick(category: String, type: String, requestCode: Int) {
    val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      this.type = type
    }
    startActivityForResult(Intent.createChooser(intent, "Choose $category"), requestCode)
  }

  private fun viewPicture(item: TransferItem) {
    val bytes = manager.payloads[item.id]
    if (bytes == null) {
      Toast.makeText(this, "Picture is no longer in memory. Downloaded files remain available.", Toast.LENGTH_LONG).show()
      return
    }
    val image = ImageView(this).apply {
      setImageURI(saveTempImage(bytes, item.fileName))
      adjustViewBounds = true
      maxHeight = dp(520)
    }
    AlertDialog.Builder(this)
      .setTitle(item.fileName)
      .setView(image)
      .setPositiveButton("OK", null)
      .show()
  }

  private fun download(item: TransferItem) {
    val bytes = manager.payloads[item.id]
    if (bytes == null) {
      Toast.makeText(this, "File is no longer in memory.", Toast.LENGTH_LONG).show()
      return
    }
    val uri = if (item.isPicture) {
      saveMedia(bytes, item.fileName, item.contentType ?: "image/jpeg", true)
    } else {
      saveMedia(bytes, item.fileName, item.contentType ?: "application/octet-stream", false)
    }
    if (uri != null) {
      manager.markDownloaded(item.id)
      Toast.makeText(this, "Downloaded: ${item.fileName}", Toast.LENGTH_LONG).show()
    }
  }

  private fun saveTempImage(bytes: ByteArray, fileName: String): Uri {
    val file = java.io.File(cacheDir, fileName)
    file.writeBytes(bytes)
    return Uri.fromFile(file)
  }

  private fun saveMedia(bytes: ByteArray, fileName: String, mimeType: String, image: Boolean): Uri? {
    val collection = if (image) {
      MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      MediaStore.Downloads.EXTERNAL_CONTENT_URI
    } else {
      MediaStore.Files.getContentUri("external")
    }
    val values = ContentValues().apply {
      put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
      put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        put(MediaStore.MediaColumns.RELATIVE_PATH, if (image) "Pictures/LocalLink" else "Download/LocalLink")
      }
    }
    val uri = contentResolver.insert(collection, values) ?: return null
    contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
    return uri
  }

  private fun displayName(uri: Uri): String? {
    contentResolver.query(uri, null, null, null, null)?.use { cursor ->
      val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
      if (index >= 0 && cursor.moveToFirst()) return cursor.getString(index)
    }
    return null
  }

  private fun selectedPeer(): DiscoveredPeer? =
    selectedPeerID?.let { id ->
      manager.peers.firstOrNull { it.identity.deviceID == id }
        ?: manager.trustedIdentities().firstOrNull { it.deviceID == id }?.let { peerFor(it) }
    }

  private fun peerFor(peer: TrustedPeer): DiscoveredPeer = manager.peerFor(peer)

  private fun platformIcon(platform: String): String =
    when (platform) {
      "iOS" -> "i"
      "macOS" -> "M"
      "android" -> "A"
      "windows" -> "W"
      else -> "?"
    }

  private fun settingRow(title: String, value: View, action: View? = null): LinearLayout =
    LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      addView(label(title, muted, 13f, false))
      val row = LinearLayout(this@MainActivity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
      }
      row.addView(
        value,
        LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
      )
      if (action != null) {
        row.addView(
          action,
          LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(42)).apply {
            setMargins(dp(10), 0, 0, 0)
          }
        )
      }
      addView(row, blockParams(top = dp(6)))
    }

  private fun copyText(text: String) {
    val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("LocalLink address", text))
  }

  private fun sectionTitle(text: String): TextView = label(text, ink, 19f, true).apply {
    setPadding(0, dp(18), 0, dp(8))
  }

  private fun label(text: String, color: Int, size: Float, bold: Boolean): TextView =
    TextView(this).apply {
      this.text = text
      textSize = size
      setTextColor(color)
      if (bold) typeface = Typeface.DEFAULT_BOLD
      includeFontPadding = true
    }

  private fun chip(text: String, textColor: Int, backgroundColor: Int = Color.rgb(241, 244, 249)): TextView =
    TextView(this).apply {
      this.text = text
      textSize = 12f
      typeface = Typeface.DEFAULT_BOLD
      setTextColor(textColor)
      gravity = Gravity.CENTER
      setPadding(dp(10), dp(4), dp(10), dp(4))
      background = rounded(backgroundColor, dp(999))
    }

  private fun card(selected: Boolean = false): LinearLayout =
    LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(dp(16), dp(14), dp(16), dp(14))
      background = rounded(surface, dp(16), if (selected) blue else line, if (selected) dp(2) else dp(1))
      elevation = dp(1).toFloat()
      layoutParams = blockParams(bottom = dp(10))
    }

  private fun emptyCard(text: String): View =
    card().apply {
      addView(label(text, muted, 15f, false))
    }

  private fun primaryButton(text: String, enabled: Boolean, onClick: () -> Unit): Button =
    Button(this).apply {
      this.text = text
      isAllCaps = false
      textSize = 15f
      setTextColor(if (enabled) Color.WHITE else muted)
      isEnabled = enabled
      background = rounded(if (enabled) blue else Color.rgb(233, 236, 242), dp(12))
      setOnClickListener { onClick() }
    }

  private fun actionButton(text: String, enabled: Boolean, danger: Boolean = false, onClick: () -> Unit): Button =
    Button(this).apply {
      this.text = text
      isAllCaps = false
      textSize = 13f
      setTextColor(
        when {
          !enabled -> muted
          danger -> red
          else -> blue
        }
      )
      isEnabled = enabled
      background = rounded(if (enabled) Color.rgb(244, 247, 252) else Color.rgb(238, 240, 244), dp(11), line)
      setOnClickListener { onClick() }
      layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(42)).apply {
        setMargins(0, 0, dp(8), 0)
      }
    }

  private fun iconButton(text: String, onClick: () -> Unit): Button =
    Button(this).apply {
      this.text = text
      isAllCaps = false
      textSize = 18f
      setTextColor(blue)
      background = rounded(blueSoft, dp(999))
      setOnClickListener { onClick() }
    }

  private fun rounded(color: Int, radius: Int, strokeColor: Int? = null, strokeWidth: Int = dp(1)): GradientDrawable =
    GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = radius.toFloat()
      setColor(color)
      if (strokeColor != null) setStroke(strokeWidth, strokeColor)
    }

  private fun blockParams(top: Int = 0, bottom: Int = 0): LinearLayout.LayoutParams =
    LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
      setMargins(0, top, 0, bottom)
    }

  private fun View.showDivider() {
    background = rounded(Color.TRANSPARENT, 0, Color.rgb(238, 240, 245))
  }

  private fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return "%.1f KB".format(kb)
    return "%.1f MB".format(kb / 1024.0)
  }

  private fun statusBarHeight(): Int {
    val id = resources.getIdentifier("status_bar_height", "dimen", "android")
    return if (id > 0) resources.getDimensionPixelSize(id) else dp(24)
  }

  private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
