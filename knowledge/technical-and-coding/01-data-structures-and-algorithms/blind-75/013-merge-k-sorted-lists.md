# 23. Merge K Sorted Lists

- **Difficulty:** Hard
- **URL:** https://leetcode.com/problems/merge-k-sorted-lists/
- **Category:** Linked List, Divide and Conquer, Heap

## Problem

You are given an array of `k` linked lists, each sorted in ascending order. Merge all the linked lists into one sorted linked list and return it.

**Example 1:**
- Input: `lists = [[1,4,5],[1,3,4],[2,6]]`
- Output: `[1,1,2,3,4,4,5,6]`

**Example 2:**
- Input: `lists = []`
- Output: `[]`

**Constraints:**
- `0 <= k <= 10^4`
- `0 <= lists[i].length <= 500`
- `-10^4 <= lists[i][i] <= 10^4`
- Each list is sorted in non-decreasing order
- Total nodes across all lists <= 10^4

## Solution

**Approach:** Divide and conquer — iteratively pair up lists and merge each pair, halving the number of lists each round. Reuses `mergeTwo` from Merge Two Sorted Lists. The drain shortcut `current.next = ptr1 ?? ptr2` is cleaner than two separate drain loops.

**Time:** O(n log k) — log k rounds, each round touches all n nodes total
**Space:** O(1) — no extra data structures beyond the merged list itself

```typescript
function mergeKLists(lists: Array<ListNode | null>): ListNode | null {
  if (lists.length == 0) return null;
  if (lists.length == 1) return lists[0];

  while (lists.length > 1) {
    let merged: Array<ListNode | null> = [];
    for (let i = 0; i < lists.length; i += 2) {
      if (i + 1 < lists.length) {
        merged.push(mergeTwo(lists[i], lists[i + 1]));
      } else {
        merged.push(lists[i]); // odd one out — carry forward
      }
    }
    lists = merged;
  }

  return lists[0] ?? null;
}

function mergeTwo(
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

  current.next = ptr1 ?? ptr2; // attach remaining list directly
  return sentinel.next;
}
```

## Key Takeaways

- **Divide and conquer** reduces O(kn) naive (merge one list at a time) to O(n log k) — same idea as merge sort
- Reusing `mergeTwo` is the right call — don't rewrite merge logic inline
- `current.next = ptr1 ?? ptr2` is a clean drain shortcut (works because at most one can be non-null at that point)
- **Alternative:** min-heap of size k — pop the smallest node, push its next. Also O(n log k) but O(k) space. Harder to implement in JS without a built-in heap.
- The odd-list-out case (`i+1 >= lists.length`) must be handled — carry it forward unmerged to the next round
