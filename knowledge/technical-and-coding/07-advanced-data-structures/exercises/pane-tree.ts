// Terminal Pane Splitter — Tree Manipulation
//
// Model a terminal that splits panes (like tmux/iTerm). Each split
// replaces an existing view with a directional container holding the
// original view and a new one.
//
// pane.split(Direction.DOWN, 1, 2)  — split view 1 downward, creating view 2
// pane.split(Direction.RIGHT, 2, 3) — split view 2 rightward, creating view 3
//
// The underlying structure is a binary tree:
//   - Leaf nodes are views (identified by numeric ID)
//   - Internal nodes are splits (direction + two children)

enum Direction {
  DOWN = "DOWN",
  RIGHT = "RIGHT",
}

type PaneNode =
  | { kind: "view"; id: number }
  | { kind: "split"; direction: Direction; first: PaneNode; second: PaneNode };

class PaneTree {
  private root: PaneNode;

  constructor(id: number) {
    this.root = { kind: "view", id };
  }

  split(direction: Direction, targetId: number, newId: number): void {
    this.root = this.splitNode(this.root, direction, targetId, newId);
  }

  private splitNode(
    node: PaneNode,
    direction: Direction,
    targetId: number,
    newId: number
  ): PaneNode {
    if (node.kind === "view") {
      if (node.id === targetId) {
        return {
          kind: "split",
          direction,
          first: { kind: "view", id: targetId },
          second: { kind: "view", id: newId },
        };
      }
      return node;
    }

    return {
      ...node,
      first: this.splitNode(node.first, direction, targetId, newId),
      second: this.splitNode(node.second, direction, targetId, newId),
    };
  }

  toString(): string {
    return this.nodeToString(this.root);
  }

  private nodeToString(node: PaneNode): string {
    if (node.kind === "view") {
      return `View ${node.id}`;
    }
    return `${node.direction}(${this.nodeToString(node.first)}, ${this.nodeToString(node.second)})`;
  }
}

// --- Verification ---

const pane = new PaneTree(1);
console.log(pane.toString()); // View 1

pane.split(Direction.DOWN, 1, 2);
console.log(pane.toString()); // DOWN(View 1, View 2)

pane.split(Direction.RIGHT, 2, 3);
console.log(pane.toString()); // DOWN(View 1, RIGHT(View 2, View 3))

pane.split(Direction.DOWN, 1, 4);
console.log(pane.toString()); // DOWN(DOWN(View 1, View 4), RIGHT(View 2, View 3))

pane.split(Direction.RIGHT, 1, 5);
console.log(pane.toString()); // DOWN(DOWN(RIGHT(View 1, View 5), View 4), RIGHT(View 2, View 3))
