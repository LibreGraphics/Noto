//
//  EditorView.swift
//  Noto
//
//  Created by Bruno Philipe on 21/2/17.
//  Copyright © 2017 Bruno Philipe. All rights reserved.
//

import Cocoa
import Carbon

class EditorView: PaddedTextView
{
	private let invisiblesLayoutManager = InvisiblesLayoutManager()
	private var tabSize: UInt = 4

	var lineCounterView: LineCounterRulerView? = nil
	var usesSpacesForTabs: Bool = false
	var keepsIndentationOnNewLines: Bool = false

	var escToLeaveFullScreenMode: WaitStatus = .none

	override var textContainerInset: NSSize
	{
		didSet
		{
			invisiblesLayoutManager.textInset = textContainerInset
			
			// Re-set selected range so that the insertion point is drawn at the right location
			self.selectedRanges = self.selectedRanges
		}
	}

	override var font: NSFont?
	{
		didSet
		{
			invisiblesLayoutManager.updateFontInformation()
		}
	}

	var showsInvisibleCharacters: Bool
	{
		get { return invisiblesLayoutManager.showsInvisibleCharacters }
		set
		{
			invisiblesLayoutManager.showsInvisibleCharacters = newValue
			needsDisplay = true
		}
	}

	override func awakeFromNib()
	{
		super.awakeFromNib()

		self.textContainer?.replaceLayoutManager(invisiblesLayoutManager)

		if let scrollView = self.enclosingScrollView
		{
			let lineCounterView = LineCounterRulerView(scrollView: scrollView, orientation: .verticalRuler)
			lineCounterView.clientView = self

			scrollView.horizontalRulerView = nil
			scrollView.verticalRulerView = lineCounterView

			scrollView.hasHorizontalRuler = false
			scrollView.hasVerticalRuler = true
			scrollView.rulersVisible = true

			self.lineCounterView = lineCounterView
		}
	}

	deinit
	{
		// Break cyclic reference before the text view deallocs
		lineCounterView?.clientView = nil

		if let scrollView = self.enclosingScrollView
		{
			scrollView.rulersVisible = false
			scrollView.hasVerticalRuler = false
			scrollView.verticalRulerView = nil
		}
	}

	override func viewWillStartLiveResize()
	{
		super.viewWillStartLiveResize()

		invisiblesLayoutManager.isResizing = true
	}

	override func viewDidEndLiveResize()
	{
		super.viewDidEndLiveResize()

		invisiblesLayoutManager.isResizing = false
		needsDisplay = true
	}

	override func insertTab(_ sender: Any?)
	{
		if usesSpacesForTabs
		{
			insertText(String.init(repeating: " ", count: Int(tabSize)), replacementRange: NSRange(location: NSNotFound, length: 0))
		}
		else
		{
			super.insertTab(sender)
		}
	}

	func jumpToLine(lineNumber: Int) -> Bool
	{
		var success = false

		if let string = self.string as NSString?
		{
			var iteratedLines = 1

			string.enumerateSubstrings(in: string.fullStringRange, options: .byLines)
			{
				(substring, range, enclosingRange, stop: UnsafeMutablePointer<ObjCBool>) in

				if lineNumber == iteratedLines
				{
					self.setSelectedRange(range)
					self.scrollRangeToVisible(range)
					stop.pointee = ObjCBool(true)
					success = true
				}

				iteratedLines += 1
			}
		}

		return success
	}

	override func keyDown(with event: NSEvent)
	{
		if event.keyCode == UInt16(kVK_Escape) && Preferences.instance.doubleEscToLeaveFullScreen
		{
			switch escToLeaveFullScreenMode
			{
			case .none:
				escToLeaveFullScreenMode = .waiting(timeout: Date().addingTimeInterval(1).timeIntervalSince1970)

			case .waiting(let timeout):
				if Date().timeIntervalSince1970 < timeout
				{
					super.keyDown(with: event)
				}

				escToLeaveFullScreenMode = .none
			}
		}
		else
		{
			super.keyDown(with: event)
		}

		if keepsIndentationOnNewLines && (event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter))
		{
			var newRanges = [NSValue]()
			var insertedChacacters = 0

			for range in selectedRanges.map({ return $0.rangeValue })
			{
				insertedChacacters += insertIndentationMatchingPreviousLineFromLocation(range.location + insertedChacacters)

				newRanges.append(NSValue(range: NSMakeRange(range.location + insertedChacacters, range.length)))
			}

			selectedRanges = newRanges
		}
	}

	func increaseIndentation()
	{
		if let ranges = textStorage?.increaseIndentForSelectedRanges(selectedRanges.map { return $0.rangeValue },
		                                                             usingUndoManager: self.undoManager)
		{
			selectedRanges = ranges.map { return NSValue(range: $0) }
		}
	}

	func decreaseIndentation()
	{
		if let ranges = textStorage?.decreaseIndentForSelectedRanges(selectedRanges.map { return $0.rangeValue },
		                                                             usingUndoManager: self.undoManager)
		{
			selectedRanges = ranges.map { return NSValue(range: $0) }
		}
	}

	private func insertIndentationMatchingPreviousLineFromLocation(_ location: Int) -> Int
	{
		if let textStorage = self.textStorage
		{
			let string: NSString = textStorage.string as NSString
			let currentLineRange = string.lineRange(for: NSMakeRange(location, 0))

			if currentLineRange.location > 0
			{
				let previousLineRange = string.lineRange(for: NSMakeRange(currentLineRange.location - 1, 0))

				var tabCount = 0

				for i in previousLineRange.location ..< (previousLineRange.location + previousLineRange.length)
				{
					if string.character(at: i).isTab()
					{
						tabCount += 1
					}
					else
					{
						break
					}
				}

				textStorage.replaceCharacters(in: NSMakeRange(currentLineRange.location, 0),
				                              with: String(repeating: "\t", count: tabCount))

				return tabCount
			}
		}

		return 0
	}

	// Has to be updated when font size changes
	func setTabWidth(_ width: UInt)
	{
		// Update paragraph style
		let paragraphStyle = (defaultParagraphStyle ?? NSParagraphStyle.default()).mutableCopy() as! NSMutableParagraphStyle
		let characterWidth = (font ?? NSFont.systemFont(ofSize: 14)).screenFont(with: .antialiasedRenderingMode).advancement(forGlyph: NSGlyph(" "))

		paragraphStyle.defaultTabInterval = CGFloat(width) * characterWidth.width
		paragraphStyle.tabStops = []

		defaultParagraphStyle = paragraphStyle

		// Re-render current text with new typing attributes
		var typingAttributes = self.typingAttributes
		typingAttributes[NSParagraphStyleAttributeName] = paragraphStyle
		self.typingAttributes = typingAttributes

		if let textString: NSString = self.string as NSString?
		{
			let textRange = NSMakeRange(0, textString.length)
			shouldChangeText(in: textRange, replacementString: nil)
			textStorage?.setAttributes(typingAttributes, range: textRange)
			didChangeText()
		}
	}
}

extension EditorView
{
	enum WaitStatus
	{
		case none
		case waiting(timeout: TimeInterval)
	}
}