# 21. Merge Two Sorted Lists

- **Difficulty:** Easy
- **URL:** https://leetcode.com/problems/merge-two-sorted-lists/
- **Category:** Linked List, Two Pointers

## Problem

You are given the heads of two sorted linked lists `list1` and `list2`. Merge the two lists into one sorted list and return the head of the merged list.

**Example 1:**
- Input: `list1 = [1,2,4], list2 = [1,3,4]`
- Output: `[1,1,2,3,4,4]`

**Example 2:**
- Input: `list1 = [], list2 = []`
- Output: `[]`

**Example 3:**
- Input: `list1 = [], list2 = [0]`
- Output: `[0]`

**Constraints:**
- `0 <= length of each list <= 50`
- `-100 <= Node.val <= 100`
- Both lists are sorted in non-decreasing order

## Solution

**Approach:** Sentinel node + two pointers. Use a dummy head node so we never have to special-case the first insertion. Advance whichever pointer has the smaller value, then drain whichever list has remaining nodes.

**Time:** O(m + n)
**Space:** O(1) — nodes are reused, not copied

```typescript
function mergeTwoLists(
  list1: ListNode | null,
  list2: ListNode | null
): ListNode | null {
  const sentinel = new ListNode(-1);
  let current = sentinel;
  let ptr1 = list1;
  let ptr2 = list2;

  while (ptr1 !== null && ptr2 !== null) {
    if (ptr1.val > ptr2.val) {
      current.next = ptr2;
      ptr2 = ptr2.next;
    } else {
      current.next = ptr1;
      ptr1 = ptr1.next;
    }
    current = current.next!;
  }

  while (ptr1 !== null) {
    current.next = ptr1;
    current = current.next!;
    ptr1 = ptr1.next;
  }

  while (ptr2 !== null) {
    current.next = ptr2;
    current = current.next!;
    ptr2 = ptr2.next;
  }

  return sentinel.next;
}
```

## Key Takeaways

- **Sentinel node** is the canonical linked list trick — eliminates the "what is the head?" special case, always return `sentinel.next`
- The drain loops (after the main while) can be simplified: once one list is exhausted you can just attach the remainder directly (`current.next = ptr1 ?? ptr2`) since both can't be non-null at that point
- This exact pattern is the building block for Merge K Sorted Lists (divide and conquer with this as the merge step)
