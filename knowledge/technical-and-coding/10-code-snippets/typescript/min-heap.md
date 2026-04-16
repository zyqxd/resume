# MinHeap (TypeScript)

Generic binary min-heap backed by an array. Accepts a custom comparator in the style of `Array.prototype.sort`: return negative if `a` should come out before `b`. For a max-heap, invert the comparator.

**Complexity:** `push` / `pop` are O(log n), `peek` / `size` are O(1).

---

## Implementation

```typescript
class MinHeap<T> {
    private data: T[] = [];
    private compare: (a: T, b: T) => number;

    constructor(compareFn: (a: T, b: T) => number) {
        this.compare = compareFn;
    }

    push(val: T) {
        this.data.push(val);
        let i = this.size() - 1;
        while (i > 0) {
            const parent = Math.floor((i - 1) / 2);
            if (this.compare(this.data[parent], this.data[i]) <= 0) break;
            [this.data[parent], this.data[i]] = [this.data[i], this.data[parent]];
            i = parent;
        }
    }

    pop(): T | undefined {
        if (this.size() === 0) return undefined;
        if (this.size() === 1) return this.data.pop();

        [this.data[0], this.data[this.size() - 1]] = [this.data[this.size() - 1], this.data[0]];
        const popped = this.data.pop();

        let i = 0;
        while (i < this.size()) {
            const left = i * 2 + 1;
            const right = i * 2 + 2;
            let smallest = i;

            if (left < this.size() && this.compare(this.data[left], this.data[smallest]) < 0) {
                smallest = left;
            }
            if (right < this.size() && this.compare(this.data[right], this.data[smallest]) < 0) {
                smallest = right;
            }

            if (smallest === i) break;
            [this.data[i], this.data[smallest]] = [this.data[smallest], this.data[i]];
            i = smallest;
        }

        return popped;
    }

    peek(): T | undefined {
        return this.data[0];
    }

    size(): number {
        return this.data.length;
    }
}
```

---

## Usage

```typescript
// Numeric min-heap
const heap = new MinHeap<number>((a, b) => a - b);
heap.push(5);
heap.push(1);
heap.push(3);
heap.pop(); // 1
heap.peek(); // 3

// Max-heap: invert the comparator
const maxHeap = new MinHeap<number>((a, b) => b - a);

// Heap of objects by priority
type Task = { id: string; priority: number };
const tasks = new MinHeap<Task>((a, b) => a.priority - b.priority);
```

---

## Notes

- The comparator must be consistent — returning `<= 0` in the sift-up check means equal elements do not swap, preserving insertion order among ties.
- `pop` on an empty heap returns `undefined` rather than throwing, matching `Array.prototype.pop`.
- For problems requiring `decrease-key` (e.g. Dijkstra with updates), this heap is not sufficient — use a lazy-delete pattern (push a new entry and skip stale ones on pop) or an indexed heap.

## Related

- [[../../07-advanced-data-structures/index|Advanced Data Structures]] — heap theory and variants
- [[../../08-search-algorithms/index|Search Algorithms]] — Dijkstra's uses a min-heap keyed on distance
