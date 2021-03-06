#import <Cocoa/Cocoa.h>

extern NSString* const SSYTabViewDidChangeItemNotification ;

/*!
 @brief    This class synchronizes an NSTabView's selection
 to either a NSSegmentedContol, or an NSToolbar.  

 @details  NSTabView has poor KVO support, but good bindings support.
 If you want to observe or control the tab view selection programatically,
 you may do so by binding to the tab view.  This class will take care of
 synchronizing the control to the tab view for you, in both directions.
 
 This class is typically instantiated in a xib.
 
 (To see a segmented control controlling tabs, look up
 at the top of the top right-side tab view of Xcode's All In One
 window.  You'll see "Detail", "Project Find", etc.)
 
 If your tab view is being controlled by a segmented control,
 usage is trivial.  Simply bind *both* the selected index of the tab view,
 and the selected index of the segmented control, to the
 selectedTabIndex of an SSYTabViewController instance.
 
 If your tab view is being controlled by a toolbar, it's a little
 more complicated, because NSToolbar does not have any bindings
 exposed.
 <ul>
 <li>Connect the toolbar outlet of an SSYTabViewController instance
 to the toolbar.  This is so that we can send it an
 setSelectedItemIdentifier: message when
 the tab view item changes.</li>
 <li>For the opposite direction, connect the action of each of
 the *selectable* toolbar items, (i.e. the ones that select tabs,
 not the Search Field, Inspector button, whatever, etc.) to the
 changeTabViewItem: action of the SSYTabViewController instance.
 This is so that we can tell the tab view to select the appropriate
 item.  (We figure out  which one sent it by looking at the sender.)</li>
 <li>Third, for the other  end in both directions, connect the
 tabView outlet of the SSYController instance to the tab view.</li>
 <li>In  order for this class to "just work" without alot of programming,
 we require that the corresponding tab view items and toolbar items
 have the same identifiers (strings).</li>
 </ul>
*/
@interface SSYTabView : NSTabView {

	NSInteger m_selectedTabIndex ;
	
	IBOutlet NSToolbar* toolbar ;
	
	BOOL m_lockOutInfiniteLoop ;
}

@property (assign) NSInteger selectedTabIndex ;

- (IBAction)changeTabViewItem:(NSToolbarItem*)sender ;


@end
